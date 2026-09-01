//
//  Item.swift
//  BrowserSelector
//
//  Created by Németh Marcell on 2026. 09. 01..
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
