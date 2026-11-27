# Telescope

**English** · [简体中文](docs/readme/README.zh-CN.md) · [Español](docs/readme/README.es.md) · [日本語](docs/readme/README.ja.md) · [한국어](docs/readme/README.ko.md)

**Use your iPhone, iPad, or Mac to view and control another computer.** Telescope is an open-source VNC client for a Mac with Screen Sharing enabled or any computer running a compatible VNC server. Pick up work on your desktop, check a Linux workstation, or open a file on a computer in another room.

| Remote control on iPhone | Touch shortcuts on iPad | Connection library on Mac |
| :---: | :---: | :---: |
| <a href="docs/readme/images/iphone-session.png"><img src="docs/readme/images/iphone-session.png" width="164" alt="Remote control on iPhone"></a> | <a href="docs/readme/images/ipad-session.png"><img src="docs/readme/images/ipad-session.png" width="250" alt="Touch shortcuts on iPad"></a> | <a href="docs/readme/images/mac-connections.jpg"><img src="docs/readme/images/mac-connections.jpg" width="405" alt="Connection library on Mac"></a> |

*Telescope screenshots with demo connections and a sample remote desktop. Select an image to see it at full size.*

## What you can do

- **Connect and reconnect.** Find nearby computers with Bonjour, enter a hostname or IP address, and save frequently used connections in folders.
- **Reach computers on another network.** Tunnel a VNC connection over SSH or find devices on your Tailscale network.
- **View or control a desktop.** Switch between viewing and control, use touch or a keyboard and mouse, and access shortcuts from the floating toolbar.
- **Work across displays.** Switch between remote monitors and open them in separate windows on Mac. Clipboard sharing and file transfer are available with compatible servers.

## Make your first connection

1. On the remote Mac, turn on **Screen Sharing** in **System Settings → General → Sharing**. On Linux or another host, start a compatible VNC server. [Apple’s Screen Sharing guide](https://support.apple.com/guide/mac-help/mh11848/mac).
2. On the same network, open Telescope and pick a computer from the nearby list, or use **Quick Connect** to enter its hostname or IP address.
3. Sign in with your remote credentials. Save the connection if you want to use it again.

## Build from source

The app targets **iOS 18+**, **iPadOS 18+**, and **macOS 15+** through Mac Catalyst. To build it, use Xcode 26 or later.

```sh
git clone https://github.com/nikeyda/Telescope.git
cd Telescope
open DeskLink.xcodeproj
```

Select the **DeskLink** scheme and run it on **My Mac (Mac Catalyst)** or an **iPhone or iPad simulator**. Configure your development team’s signing in Xcode to run on a physical iPhone or iPad.

## License

Telescope is available under the [MIT License](LICENSE). See the [third-party notices](App/Acknowledgements.txt) for dependency licenses.
