//
//  APRSMonitorWidgetBundle.swift
//  APRSMonitorWidget
//
//  Entry point for the widget extension. Hosts only the APRS monitoring Live
//  Activity (no Home Screen widgets or controls).
//

import WidgetKit
import SwiftUI

@main
struct APRSMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        APRSMonitorWidgetLiveActivity()
    }
}
