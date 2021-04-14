# Deft Simple USB

Usermode support for USB devices.

## Requirements

- Swift Package Manager
- Swift 5.2+
- macOS or Linux

Mac requirements
- Xcode 11.6+ suggested

SPM Dependencies
- swift-log

Linux C library dependencies 
- libusb


## Installation Notes

### Linux device permissions

On Linux, users will not have access to a hot-plugged USB device by default. 
The cleanest way to systematically grant permissions to the device is to set up a udev
rule that adjusts permissions whenever the device is connected.

The paths and group in the template below assume:
- Configuration files are under /etc/udev/rules.d
- The group 'plugdev' exists and includes the user wanting to use the device

Under /etc/udev/rules.d/, create a file (suggested name: "70-gpio-ftdi-ft232h.rules") with the contents:

    # FTDI FT232H USB -> GPIO + serial adapter
    # 2020-09-07 support working with the FT232H using Swift ftdi-synchronous-serial library
    ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6014", MODE="660", GROUP="plugdev"

eLinux.org has a useful wiki entry on [accessing devices without sudo](https://elinux.org/Accessing_Devices_without_Sudo).


## History

Extracted from the ftdi-synchronous-serial project.

To overlay the full history of these files:

- Clone this project
- Add the ftdi project as a remote:
  - git remote add ftdi https://github.com/didactek/ftdi-synchronous-serial.git
  - git fetch ftdi SIMPLE-USB-FORKPOINT tag
- Mark the replace point (tags for this are included in each repo)
  - git replace SIMPLE-USB-PREHISTORY SIMPLE-USB-FORKPOINT
