//
//  SimpleUSBDevice.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-28.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Protocol for communicating with a USB-attached device.
public protocol USBDevice {
    /// Send a control transfer packet to the device (endpoint zero).
    func controlTransferOut(bRequest: UInt8, value: UInt16, wIndex: UInt16, data: Data?)

    /// Send data on the write endpoint.
    func bulkTransferOut(msg: Data)

    /// Fetch all data availble on the read endpoint.
    func bulkTransferIn() -> Data

    /// Timeout to use on bulk/conttrol transfer operations
    var timeout: TimeInterval {get set}

    /// Format a bmRequestType byte.
    /// - Note: similar to IOUSBHostPipe.IOUSBHostDeviceRequestType
    func controlRequest(type: ControlRequestType, direction: ControlDirection, recipient: ControlRequestRecipient) -> BMRequestType
}
