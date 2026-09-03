// SPDX-License-Identifier: Apache-2.0
//
// bmc-assoc — generic, config-driven inventory + association shim.
//
// Publishes one chassis inventory object per config file, plus an `all_sensors`
// association to that device's phosphor-hwmon sensors, so bmcweb exposes them at
// /redfish/v1/Chassis/<chassis>/Sensors. This is the piece a full OpenBMC image
// gets from entity-manager; on Kuiper (Debian, no entity-manager) we provide it.
//
// It is DEVICE-AGNOSTIC: rather than hardcoding one device in C++, it reads
// plain-text config files (default /etc/bmc-assoc/*.conf), so adding a device is
// a drop-in file + `systemctl restart bmc-assoc` — no recompile, no image
// rebuild. One process owns one bus name and publishes every configured chassis
// under a single ObjectManager.
//
// Config file format (key=value; '#' starts a comment; blank lines ignored):
//
//     # /etc/bmc-assoc/adm1600.conf
//     CHASSIS=adm1600                 # required: chassis leaf name
//     NAME=adm1600                    # optional: Inventory.Item Name (default=CHASSIS)
//     SENSOR=voltage/adm1600_Vin      # >=1: sensor subpath under the sensor root,
//     SENSOR=current/adm1600_Iin      #      or an absolute /xyz/... object path
//     SENSOR=power/adm1600_Pin
//     # SENSOR_ROOT=/xyz/openbmc_project/sensors   # optional override
//
// Each SENSOR yields the association tuple (all_sensors, chassis, <path>).
// phosphor-objmgr synthesises the reverse endpoints (<chassis>/all_sensors and
// <sensor>/chassis) once the sensor objects exist — pending associations
// self-heal, so start order versus the hwmon poller does not matter.
//
// The SENSOR subpaths MUST match the phosphor-hwmon LABEL_* values for the
// device (see its <device>-hwmon.conf): the hwmon channel decides the <type>
// segment (in->voltage, curr->current, power->power, temp->temperature,
// fan->fan_tach) and LABEL_* decides the leaf.

#include <boost/asio/io_context.hpp>
#include <sdbusplus/asio/connection.hpp>
#include <sdbusplus/asio/object_server.hpp>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

namespace
{

using Association = std::tuple<std::string, std::string, std::string>;

constexpr const char* busName = "xyz.openbmc_project.BmcAssoc";
constexpr const char* inventoryRoot = "/xyz/openbmc_project/inventory";
constexpr const char* chassisRoot =
    "/xyz/openbmc_project/inventory/system/chassis";
constexpr const char* defaultSensorRoot = "/xyz/openbmc_project/sensors";
constexpr const char* defaultConfDir = "/etc/bmc-assoc";

struct ChassisConfig
{
    std::string chassis;              // leaf name (required)
    std::string name;                 // Inventory.Item Name (default = chassis)
    std::string sensorRoot = defaultSensorRoot;
    std::vector<std::string> sensors; // fully-resolved sensor object paths
};

std::string trim(std::string s)
{
    auto notSpace = [](unsigned char c) { return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
    s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
    return s;
}

// Parse one .conf file into `out`. Returns false (with a message) when the file
// has no CHASSIS or no SENSOR — a malformed file is skipped, never fatal, so one
// bad drop-in cannot take down the others.
bool parseConf(const std::filesystem::path& p, ChassisConfig& out)
{
    std::ifstream in(p);
    if (!in)
    {
        std::cerr << "bmc-assoc: cannot open " << p << "\n";
        return false;
    }

    std::vector<std::pair<std::string, std::string>> kv;
    std::string line;
    while (std::getline(in, line))
    {
        if (auto hash = line.find('#'); hash != std::string::npos)
        {
            line.erase(hash);
        }
        line = trim(line);
        if (line.empty())
        {
            continue;
        }
        auto eq = line.find('=');
        if (eq == std::string::npos)
        {
            continue;
        }
        kv.emplace_back(trim(line.substr(0, eq)), trim(line.substr(eq + 1)));
    }

    // Resolve SENSOR_ROOT first so SENSOR entries are order-independent.
    for (const auto& [k, v] : kv)
    {
        if (k == "SENSOR_ROOT" && !v.empty())
        {
            out.sensorRoot = v;
        }
    }
    for (const auto& [k, v] : kv)
    {
        if (k == "CHASSIS")
        {
            out.chassis = v;
        }
        else if (k == "NAME")
        {
            out.name = v;
        }
        else if (k == "SENSOR" && !v.empty())
        {
            out.sensors.push_back(v.front() == '/' ? v
                                                   : out.sensorRoot + "/" + v);
        }
    }

    if (out.chassis.empty())
    {
        std::cerr << "bmc-assoc: " << p << ": missing CHASSIS, skipping\n";
        return false;
    }
    if (out.sensors.empty())
    {
        std::cerr << "bmc-assoc: " << p << " (" << out.chassis
                  << "): no SENSOR entries, skipping\n";
        return false;
    }
    if (out.name.empty())
    {
        out.name = out.chassis;
    }
    return true;
}

// Load every config from a directory (its *.conf files, sorted) or a single
// file path.
std::vector<ChassisConfig> loadConfigs(const std::string& pathArg)
{
    std::vector<ChassisConfig> cfgs;
    std::error_code ec;
    std::filesystem::path p(pathArg);
    std::vector<std::filesystem::path> files;

    if (std::filesystem::is_directory(p, ec))
    {
        for (const auto& e : std::filesystem::directory_iterator(p, ec))
        {
            if (e.is_regular_file() && e.path().extension() == ".conf")
            {
                files.push_back(e.path());
            }
        }
        std::sort(files.begin(), files.end());
    }
    else if (std::filesystem::is_regular_file(p, ec))
    {
        files.push_back(p);
    }
    else
    {
        std::cerr << "bmc-assoc: config path not found: " << pathArg << "\n";
    }

    for (const auto& f : files)
    {
        ChassisConfig c;
        if (parseConf(f, c))
        {
            cfgs.push_back(std::move(c));
        }
    }
    return cfgs;
}

} // namespace

int main(int argc, char** argv)
{
    const std::string confPath = (argc > 1) ? argv[1] : defaultConfDir;
    const auto configs = loadConfigs(confPath);

    if (configs.empty())
    {
        // Own the name and idle rather than crash-loop: dropping in a .conf and
        // restarting the service is then all it takes to bring a device up.
        std::cerr << "bmc-assoc: no valid chassis configs under " << confPath
                  << "; idling (add a .conf and restart bmc-assoc)\n";
    }

    boost::asio::io_context io;
    auto conn = std::make_shared<sdbusplus::asio::connection>(io);
    conn->request_name(busName);

    sdbusplus::asio::object_server server(conn);
    // ObjectManager at the inventory root so InterfacesAdded is emitted for the
    // chassis objects below — that is how phosphor-objmgr discovers them.
    server.add_manager(inventoryRoot);

    // Retain every interface for the process lifetime.
    std::vector<std::shared_ptr<sdbusplus::asio::dbus_interface>> keep;

    for (const auto& c : configs)
    {
        const std::string chassisPath =
            std::string(chassisRoot) + "/" + c.chassis;

        std::vector<Association> associations;
        associations.reserve(c.sensors.size());
        for (const auto& s : c.sensors)
        {
            associations.emplace_back("all_sensors", "chassis", s);
        }

        auto item = server.add_interface(chassisPath,
                                         "xyz.openbmc_project.Inventory.Item");
        item->register_property("Name", c.name);
        item->register_property("Present", true);
        item->initialize();
        keep.push_back(item);

        auto board = server.add_interface(
            chassisPath, "xyz.openbmc_project.Inventory.Item.Board");
        board->initialize();
        keep.push_back(board);

        auto assoc = server.add_interface(
            chassisPath, "xyz.openbmc_project.Association.Definitions");
        assoc->register_property("Associations", associations);
        assoc->initialize();
        keep.push_back(assoc);

        std::cerr << "bmc-assoc: published " << chassisPath << " with "
                  << associations.size() << " sensor association(s)\n";
    }

    io.run();
    return 0;
}
