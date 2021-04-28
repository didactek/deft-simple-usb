//
//  BMRequest.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-28.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

// USB spec 2.0, sec 9.3: USB Device Requests
// USB spec 2.0, sec 9.3.1: bmRequestType
public typealias BMRequestType = UInt8
public enum ControlDirection: BMRequestType {
    case hostToDevice = 0b0000_0000
    case deviceToHost = 0b1000_0000
}
public enum ControlRequestType: BMRequestType {
    case standard = 0b00_00000
    case `class`  = 0b01_00000
    case vendor   = 0b10_00000
    case reserved = 0b11_00000
}
public enum ControlRequestRecipient: BMRequestType {
    case device = 0
    case interface = 1
    case endpoint = 2
    case other = 3
}
