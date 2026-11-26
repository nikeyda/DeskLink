"""Run desktop and SSH tests through a paired device tunnel or the local Pi fixture."""

import asyncio
import base64
import contextlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import sys
import tempfile
import uuid


def tunnel_addresses(device):
    details = subprocess.check_output([
        "xcrun", "devicectl", "device", "info", "details", "--device", device,
        "--quiet", "--json-output", "/dev/stdout", "--timeout", "10",
    ])
    connection = json.loads(details)["result"]["connectionProperties"]
    if connection.get("pairingState") != "paired" or connection.get("tunnelState") != "connected":
        raise ValueError("The selected iPad needs a connected developer tunnel.")
    peer = ipaddress.IPv6Address(connection["tunnelIPAddress"])
    route = subprocess.check_output(["route", "-n", "get", "-inet6", str(peer)], text=True)
    interface = re.search(r"^\s*interface: (utun\d+)\s*$", route, re.MULTILINE)
    if not interface or peer not in ipaddress.ip_network("fc00::/7"):
        raise ValueError("Could not identify a private, point-to-point developer interface.")
    addresses = subprocess.check_output(["ifconfig", interface.group(1)], text=True)
    subnet = ipaddress.ip_network((peer, 64), strict=False)
    candidates = [ipaddress.IPv6Address(value) for value in re.findall(r"inet6 ([0-9a-f:]+) ", addresses)]
    local, = [address for address in candidates if address in subnet and address != peer]
    return str(local), str(peer)


async def forward_guest(reader, writer, peer, port):
    try:
        if writer.get_extra_info("peername")[0] != peer:
            return
        upstream, output = await asyncio.open_connection("127.0.0.1", port)

        async def copy(source, target):
            while data := await source.read(65536):
                target.write(data)
                await target.drain()

        tasks = [asyncio.create_task(copy(reader, output)), asyncio.create_task(copy(upstream, writer))]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            output.close()
    except OSError:
        pass  # TigerVNC deliberately drops the transport in the reconnection test.
    finally:
        writer.close()


def fixture(directory, local, ssh):
    if ssh:
        identity = json.loads((directory / "peer.json").read_text())
        keys = base64.b64encode((directory / "test-keys.json").read_bytes()).decode("ascii")
        environment = {"DESKLINK_SSH_HOST": local, "DESKLINK_SSH_PIN": identity["pin"], "DESKLINK_KEY_FIXTURES": keys}
        return environment, {"DESKLINK_SSH_PORT": int(identity["port"])}, ["SSHWireTests", "SSHAndRouteTests"]
    environment = {"DESKLINK_LINUX_HOST": local, "DESKLINK_TLS_PIN": (directory.parent / "tls-pin").read_text().strip()}
    names = {"DESKLINK_LINUX_PORT": "vnc-port", "DESKLINK_TLS_PORT": "tls-port",
             "DESKLINK_WAYLAND_PORT": "wayland-port", "DESKLINK_RESIZE_PORT": "resize-port"}
    return environment, {name: int((directory / file).read_text()) for name, file in names.items()}, ["LinuxDesktopTests"]


async def test(device, fixture_directory, manifest_path, result_path, ssh=False, pinyin=False, local_pi=False):
    local, peer = ("127.0.0.1", None) if local_pi else tunnel_addresses(device)
    directory = Path(fixture_directory)
    pi_account = local_pi or os.environ.get("DESKLINK_TEST_PI_DESKTOP_ACCOUNT") == "1"
    rsa_ui = not pi_account and os.environ.get("DESKLINK_TEST_RSA_UI") == "1"
    if not pi_account and (bits := os.environ.get("DESKLINK_TEST_RSA_AES")):
        environment = {"DESKLINK_LINUX_HOST": local, "DESKLINK_RSA_BITS": bits,
                       "DESKLINK_RSA_PIN": (directory.parent / "rsa-pin").read_text().strip()}
        environment["DESKLINK_RSA_ACCOUNT"] = os.environ.get("DESKLINK_TEST_RSA_ACCOUNT", "0")
        ports = {"DESKLINK_RSA_PORT": int((directory / "resize-port").read_text())}
        cases = ["LinuxDesktopTests/testRSAAESHostApprovalPasswordAndEncryptedDesktopInput",
                 "RSAAESRecordTests", "ScreensArchiveTests"]
        if rsa_ui:
            if bits != "256" or environment["DESKLINK_RSA_ACCOUNT"] != "1":
                raise ValueError("The RSA UI check needs a 256-bit account fixture.")
            cases = ["SessionUITests/testRaspberryPiAuthenticationPickerHostFingerprintAndLiveEncryptionReport"]
    elif pi_account:
        environment = {"DESKLINK_LINUX_HOST": local, "DESKLINK_TEST_PI_DESKTOP_ACCOUNT": "1",
                       "DESKLINK_RSA_PIN": (directory.parent / "rsa-pin").read_text().strip(),
                       "DESKLINK_TLS_PIN": (directory.parent / "tls-pin").read_text().strip()}
        ports = {"DESKLINK_WAYLAND_PORT": int((directory / "wayland-port").read_text())}
        cases = ["LinuxDesktopTests/testRaspberryPiRequiresTheActiveDesktopAccount",
                 "LinuxDesktopTests/testRaspberryPiAuthenticatesTheDesktopAccountAndReceivesReturn",
                 "LinuxDesktopTests/testWayVNCAuthenticatesWithTLSAndDeliversWaylandKeyboardInput",
                 "LinuxDesktopTests/testWayVNCRejectsAnIncorrectPasswordForTheFixtureAccount"]
    elif pinyin:
        environment = {"DESKLINK_TEST_PINYIN": "1"}
        ports = {"DESKLINK_RESIZE_PORT": int((directory / "resize-port").read_text())}
        cases = ["SessionUITests/testPinyinCandidateSendsOnlyCommittedCharactersToTheRemoteDesktop",
                 "SessionUITests/testSelectedPinyinCandidateArrivesInTheLinuxTerminal"]
    else:
        environment, ports, cases = fixture(directory, local, ssh)
    manifest = Path(manifest_path)
    settings = plistlib.loads(manifest.read_bytes())
    target_name = "DeskLinkUITests" if pinyin or rsa_ui else "DeskLinkTests"
    target = settings[target_name]
    async with contextlib.AsyncExitStack() as stack:
        for name, port in ports.items():
            if local_pi:
                environment[name] = str(port)
                continue
            server = await asyncio.start_server(
                lambda r, w, p=port: forward_guest(r, w, peer, p), local, 0, family=socket.AF_INET6)
            await stack.enter_async_context(server)
            environment[name] = str(server.sockets[0].getsockname()[1])
        if rsa_ui:
            environment["DESKLINK_RSA_UI_TERMINAL"] = f"vnc://[{local}]:{environment['DESKLINK_RSA_PORT']}"
        if pinyin:
            environment["DESKLINK_TEST_PINYIN_TERMINAL"] = f"vnc://[{local}]:{environment['DESKLINK_RESIZE_PORT']}"
        target["EnvironmentVariables"].update(environment)
        target["CommandLineArguments"] = ["--test-library", str(uuid.uuid4())]
        target["OnlyTestIdentifiers"] = cases
        target["SystemAttachmentLifetime"] = "keepNever"
        target["UserAttachmentLifetime"] = "keepAlways" if rsa_ui else "keepNever"
        # Keep __TESTROOT__ relative to the products also used by Xcode's generated manifest.
        with tempfile.NamedTemporaryFile(dir=manifest.parent, suffix=".xctestrun") as temporary:
            plistlib.dump({"__xctestrun_metadata__": settings["__xctestrun_metadata__"], target_name: target}, temporary)
            temporary.flush()
            destination = device if local_pi else "platform=iOS,arch=arm64,id=" + device
            process = await asyncio.create_subprocess_exec(
                "xcodebuild", "-quiet", "-xctestrun", temporary.name, "-destination", destination,
                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath",
                result_path, "test-without-building")
            try:
                return await process.wait()
            finally:
                if process.returncode is None:
                    process.terminate()
                    await process.wait()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--local-address":
        print(tunnel_addresses(sys.argv[2])[0])
    elif len(sys.argv) == 5:
        sys.exit(asyncio.run(test(*sys.argv[1:])))
    elif len(sys.argv) == 6 and sys.argv[1] == "--pi-local":
        sys.exit(asyncio.run(test(*sys.argv[2:], local_pi=True)))
    elif len(sys.argv) == 6 and sys.argv[1] == "--ssh":
        sys.exit(asyncio.run(test(*sys.argv[2:], ssh=True)))
    elif len(sys.argv) == 6 and sys.argv[1] == "--pinyin":
        sys.exit(asyncio.run(test(*sys.argv[2:], pinyin=True)))
    else:
        sys.exit("Pass --local-address DEVICE, [--ssh | --pinyin] DEVICE FIXTURE_DIRECTORY XCTESTRUN RESULT, or --pi-local DESTINATION FIXTURE_DIRECTORY XCTESTRUN RESULT.")
