//
//  Item.swift
//  JaryneticsUtility
//
//  Created by Fred Thomas, Jr. on 9/24/26.
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
