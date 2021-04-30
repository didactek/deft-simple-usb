//
//  PortableUSB.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-29.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

import LibUSB
import HostFWUSB
import SimpleUSB

public class PortableUSB {
    public static func platformBus() -> USBBus {
        // FIXME: return something available for the 'platform'
        return FWUSBBus()
    }
}
