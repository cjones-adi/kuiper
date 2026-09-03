// SPDX-License-Identifier: Apache-2.0
//
// Minimal xyz.openbmc_project.User.Manager provider so bmcweb can complete
// interactive (web UI) login.
//
// After PAM authenticates the user (see /etc/pam.d/webserver: local users must
// be in the 'redfish' group), bmcweb calls
//     xyz.openbmc_project.User.Manager.GetUserInfo(username)
// at /xyz/openbmc_project/user to obtain the user's Redfish role. On a real
// OpenBMC image phosphor-user-manager answers this; we do not run it, so without
// this shim the D-Bus call fails and login returns HTTP 500 (PAM already
// succeeded -- this is only the role lookup).
//
// GetUserInfo is answered from the user's actual Unix groups: members of
// 'redfish'/'sudo'/'priv-admin' get priv-admin, everyone else priv-user. This
// shim does NOT manage users (no create/delete) -- accounts are managed with the
// normal Debian tools (useradd/usermod/passwd), which is fine for a sensor-
// monitoring bench where bmcweb auth is disabled anyway.
//
// Isolation: owns ONLY xyz.openbmc_project.User.Manager and is consulted solely
// during login. It never touches the sensor pipeline (phosphor-hwmon Sensor.Value
// objects, the chassis, or the associations), so it cannot affect sensor Redfish
// endpoints, which bmcweb serves without auth.

#include <boost/asio/io_context.hpp>
#include <sdbusplus/asio/connection.hpp>
#include <sdbusplus/asio/object_server.hpp>

#include <grp.h>
#include <pwd.h>

#include <algorithm>
#include <map>
#include <memory>
#include <string>
#include <variant>
#include <vector>

namespace
{

// Resolve every Unix group (primary + supplementary) the user belongs to.
std::vector<std::string> unixGroupsOf(const std::string& user)
{
    std::vector<std::string> names;

    struct passwd pw{};
    struct passwd* pwres = nullptr;
    std::vector<char> pbuf(16384);
    if (getpwnam_r(user.c_str(), &pw, pbuf.data(), pbuf.size(), &pwres) != 0 ||
        pwres == nullptr)
    {
        return names; // unknown/remote user -> no local groups
    }

    int ngroups = 64;
    std::vector<gid_t> gids(static_cast<size_t>(ngroups));
    if (getgrouplist(user.c_str(), pw.pw_gid, gids.data(), &ngroups) < 0)
    {
        gids.resize(static_cast<size_t>(ngroups));
        (void)getgrouplist(user.c_str(), pw.pw_gid, gids.data(), &ngroups);
    }
    gids.resize(static_cast<size_t>(ngroups));

    for (gid_t g : gids)
    {
        struct group gr{};
        struct group* grres = nullptr;
        std::vector<char> gbuf(16384);
        if (getgrgid_r(g, &gr, gbuf.data(), gbuf.size(), &grres) == 0 &&
            grres != nullptr && gr.gr_name != nullptr)
        {
            names.emplace_back(gr.gr_name);
        }
    }
    return names;
}

bool hasGroup(const std::vector<std::string>& groups, const char* name)
{
    return std::find(groups.begin(), groups.end(), name) != groups.end();
}

} // namespace

int main()
{
    using Variant = std::variant<bool, std::string, std::vector<std::string>>;
    using UserInfoMap = std::map<std::string, Variant>;

    constexpr const char* busName = "xyz.openbmc_project.User.Manager";
    constexpr const char* objPath = "/xyz/openbmc_project/user";
    constexpr const char* iface = "xyz.openbmc_project.User.Manager";

    boost::asio::io_context io;
    auto conn = std::make_shared<sdbusplus::asio::connection>(io);
    conn->request_name(busName);

    sdbusplus::asio::object_server server(conn);
    auto mgr = server.add_interface(objPath, iface);

    // a{sv} GetUserInfo(s userName). bmcweb (populateUserInfo) reads
    // UserPrivilege, RemoteUser, and for local users UserPasswordExpired +
    // UserGroups; extra keys are ignored.
    mgr->register_method(
        "GetUserInfo", [](const std::string& userName) -> UserInfoMap {
            std::vector<std::string> groups = unixGroupsOf(userName);
            const bool isAdmin = hasGroup(groups, "redfish") ||
                                 hasGroup(groups, "sudo") ||
                                 hasGroup(groups, "priv-admin");

            UserInfoMap info;
            info["UserPrivilege"] =
                std::string(isAdmin ? "priv-admin" : "priv-user");
            info["UserGroups"] = groups;
            info["RemoteUser"] = false;
            info["UserPasswordExpired"] = false;
            info["UserLockedForFailedAttempt"] = false;
            info["UserEnabled"] = true;
            return info;
        });

    mgr->initialize();

    io.run();
    return 0;
}
