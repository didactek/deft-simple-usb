//
//  USBError.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-28.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

public enum USBError: Error {
    case bindingDeviceHandle(String)
    case getConfiguration(String)
    case claimInterface(String)
}
