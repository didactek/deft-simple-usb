//
//  SimpleUSBBus.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-28.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

public protocol USBBus {
    /// - parameter idVendor: filter found devices by vendor, if not-nil.
    /// - parameter idProduct: filter found devices by product, if not-nil. Requires idVendor.
    /// - returns: the one device that matches the search criteria
    /// - throws: if device is not found or criteria are not unique
    func findDevice(idVendor: Int?, idProduct: Int?) throws -> USBDevice
}
