//
//  DeviceCommon.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-28.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation



extension USBDevice {
    public func controlRequest(type: ControlRequestType, direction: ControlDirection, recipient: ControlRequestRecipient) -> BMRequestType {
        return type.rawValue | direction.rawValue | recipient.rawValue
    }
}

public protocol DeviceCommon: USBDevice {
    /// Synchronously send USB control transfer.
    /// - returns: number of bytes transferred (if success)
    func controlTransfer(requestType: BMRequestType, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data?, wLength: UInt16) -> Int32
}

extension DeviceCommon {
    public func controlTransferOut(bRequest: UInt8, value: UInt16, wIndex: UInt16, data: Data?) {
        let requestType = controlRequest(type: .vendor, direction: .hostToDevice, recipient: .device)
        let requestSize = data?.count ?? 0

        let result = controlTransfer(requestType: requestType,
                                     bRequest: bRequest,
                                     wValue: value, wIndex: wIndex,
                                     data: data,
                                     wLength: UInt16(requestSize))

        guard result == requestSize else {
            // FIXME: should probably throw rather than abort, and maybe not all calls need to be this strict
            fatalError("controlTransferOut failed: transferred \(result) bytes of \(requestSize)")
        }
    }
}
