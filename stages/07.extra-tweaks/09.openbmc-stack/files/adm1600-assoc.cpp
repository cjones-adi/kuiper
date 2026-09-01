// SPDX-License-Identifier: Apache-2.0
//
// Minimal inventory + association shim so bmcweb exposes the ADM1600's
// phosphor-hwmon sensors under Redfish. Without this, phosphor-hwmon publishes
// Sensor.Value objects but no chassis/association exists, so
// /redfish/v1/Chassis/adm1600/Sensors is empty (see the "bmcweb needs
// associations" analysis).
//
// It publishes ONE inventory object:
//   /xyz/openbmc_project/inventory/system/chassis/adm1600
// implementing:
//   - xyz.openbmc_project.Inventory.Item        (Name, Present)
//   - xyz.openbmc_project.Inventory.Item.Board  (matches bmcweb chassisInterfaces)
//   - xyz.openbmc_project.Association.Definitions (Associations = a(sss))
//
// phosphor-objmgr's association manager turns each (forward, reverse, endpoint)
// tuple into the endpoint objects bmcweb reads:
//   <chassis>/all_sensors  -> [ sensor paths ]
//   <sensor>/chassis       -> [ chassis path ]
//
// The sensor object paths are fixed by the phosphor-hwmon LABEL_* config
// (adm1600-hwmon.conf): voltage/adm1600_Vin, current/adm1600_Iin,
// power/adm1600_Pin.

#include <boost/asio/io_context.hpp>
#include <sdbusplus/asio/connection.hpp>
#include <sdbusplus/asio/object_server.hpp>

#include <memory>
#include <string>
#include <tuple>
#include <vector>

int main()
{
    using Association = std::tuple<std::string, std::string, std::string>;

    constexpr const char* busName = "xyz.openbmc_project.adm1600.Inventory";
    const std::string chassisPath =
        "/xyz/openbmc_project/inventory/system/chassis/adm1600";
    constexpr const char* sensorRoot = "/xyz/openbmc_project/sensors";

    // (forward, reverse, endpoint): chassis --all_sensors--> each sensor,
    // and each sensor --chassis--> chassis (synthesised by phosphor-objmgr).
    const std::vector<Association> associations = {
        {"all_sensors", "chassis",
         std::string(sensorRoot) + "/voltage/adm1600_Vin"},
        {"all_sensors", "chassis",
         std::string(sensorRoot) + "/current/adm1600_Iin"},
        {"all_sensors", "chassis",
         std::string(sensorRoot) + "/power/adm1600_Pin"},
    };

    boost::asio::io_context io;
    auto conn = std::make_shared<sdbusplus::asio::connection>(io);
    conn->request_name(busName);

    sdbusplus::asio::object_server server(conn);

    // ObjectManager at the inventory root so InterfacesAdded is emitted for the
    // objects below it (this is how the mapper discovers the associations).
    server.add_manager("/xyz/openbmc_project/inventory");

    auto item =
        server.add_interface(chassisPath, "xyz.openbmc_project.Inventory.Item");
    item->register_property("Name", std::string("adm1600"));
    item->register_property("Present", true);
    item->initialize();

    auto board = server.add_interface(
        chassisPath, "xyz.openbmc_project.Inventory.Item.Board");
    board->initialize();

    auto assoc = server.add_interface(
        chassisPath, "xyz.openbmc_project.Association.Definitions");
    assoc->register_property("Associations", associations);
    assoc->initialize();

    io.run();
    return 0;
}
