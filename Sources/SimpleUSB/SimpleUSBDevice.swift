//
//  SimpleUSBDevice.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-28.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//
import Foundation

public protocol USBDevice {
    func controlTransferOut(bRequest: UInt8, value: UInt16, wIndex: UInt16, data: Data?)

    func bulkTransferOut(msg: Data)
    func bulkTransferIn() -> Data

    var timeout: TimeInterval {get set}

    // basically IOUSBHostPipe.IOUSBHostDeviceRequestType
    func controlRequest(type: ControlRequestType, direction: ControlDirection, recipient: ControlRequestRecipient) -> BMRequestType
}
