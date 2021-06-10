# Deft Simple USB

Usermode support for writing custom USB device drivers in Swift on macOS and Linux.

## API

### Usage

Deft Simple USB provides a synchronous API.

Supports
- Find device by vendor and product ID
- Bulk transfer in/out to device
- Control transfer requests to device

### Logging

Loggers are instantiated using the [deft-log](https://github.com/didactek/deft-log.git) library
using the label prefix `com.didactek.deft-simple-usb`.

## Requirements

- Swift Package Manager
- Swift 5.3+
- macOS or Linux

Mac requirements
- Xcode 12+

SPM Dependencies
- deft-log (transitively: swift-log)

macOS C library dependencies
- (libusb is optional)

Linux C library dependencies 
- libusb

### Support for older environments

Older environments are relatively easily supported by replacing the .target(name:condition:(.when))
dependencies in the Package.swift with appropriate hardcoded descriptions. The code was
largely developed with Swift 5.2. The IOUSBHost framework appeared in macOS 10.15 (Catalina),
and the libusb library should be available on most platforms.


## Platform Notes

### macOS

#### IOUSBHost implementation

The default provider of the USBBus protocol on macOS is the HostFWUSB module, which is
built on the IOUSBHost usermode framework. PortableUSB.platformBus() will vend one of these,
one can be instantiated directly.

There are no external dependencies, certifications, or special permissions required to build
and use this implementation.

#### libusb.info implementation

The LibUSB module (and its bridge module CLibUSB) that provides services on Linux will
also work on macOS.

The Swift Package Manager will install libraries according to the Package.swift manifest. On
macOS, this requires two additional tools be installed:

- brew (for SPM to fetch and install libraries)
- pkg-config (available from brew, for SPM to locate, validate, and link with installed libraries)

A quick homebrew test should show 

  % pkg-config --libs libusb-1.0
  -L/usr/local/Cellar/libusb/1.0.23/lib -lusb-1.0

If brew is installed with a nonstandard prefix (e.g., somewhere under a user's home directory),
you may need a symlink for pkg-config so it can be found by Xcode. (Notably, Xcode will search
/usr/local/bin.)



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
