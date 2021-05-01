//
//  PortableUSB.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-29.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//


import SimpleUSB

// Note: Linking of library modules is controlled by the dependencies defined in
// Package.swift, but modules that are in this pacakge **that are not part of
// the dependency tree** still pass the canImport test. (And can be imported but
// will cause linkage failures.) [SR-1393](https://bugs.swift.org/browse/SR-1393).
//
// The ideal implementation would be to use the package file to add dependencies
// for the implementation the user desires, and then use canImport to decide
// which of those to use in this file.
//
// Since we can't do that, we some big Don't-Repeat-Yourself violations here:
// - the dependency logic in the package file needs to be duplicated as
//   conditional #if logic in the imports/implementation in this file
// - we use operating system as a poor proxy for the desired implementation
//
// (LibUSB can be used on macOS; the open-source runtime might someday
// accommodate the IOUSBHost framework; other implemenations are possible)


#if USE_LIBUSB
import LibUSB
#endif

#if USE_FWUSB
import HostFWUSB
#endif

public class PortableUSB {
    public static func platformBus() -> USBBus {
        #if USE_LIBUSB
        return LUUSBBus()
        #endif

        #if USE_FWUSB
        return FWUSBBus()
        #endif
    }
}





