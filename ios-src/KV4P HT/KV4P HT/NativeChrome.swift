import SwiftUI
import UIKit

/// In dark mode the native bars and controls draw in `UIColor.label` (white), the
/// brightest thing on screen in Night. SwiftUI has no hook for most of them, so
/// recolor the UIKit views behind them.
///
/// UIAppearance proxies cover views created later (new tabs, sheets, pushes), but
/// don't touch views already on screen — so the same styling is also applied to
/// every live instance. No view identity is touched, so nav and tab state survive.
@MainActor
enum NativeChrome {
    /// nil = system look (Light/Dark/System).
    static func apply(_ theme: AppTheme) {
        let palette = theme.mode == .night ? Palette(theme) : nil

        style(UINavigationBar.appearance(), palette)
        style(UISegmentedControl.appearance(), palette)
        style(UITabBar.appearance(), palette)
        UITabBarItem.appearance().setTitleTextAttributes(palette.map { [.foregroundColor: $0.label2] }, for: .normal)
        style(UISlider.appearance(), palette)
        style(UISwitch.appearance(), palette)

        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] { restyle(window, palette) }
        }
    }

    private struct Palette {
        let label: UIColor, label2: UIColor, bg: UIColor
        init(_ t: AppTheme) { label = UIColor(t.label); label2 = UIColor(t.label2); bg = UIColor(t.bg) }
    }

    private static func restyle(_ view: UIView, _ p: Palette?) {
        switch view {
        case let v as UINavigationBar:     style(v, p)
        case let v as UISegmentedControl:  style(v, p)
        case let v as UITabBar:            style(v, p)
        case let v as UISlider:            style(v, p)
        case let v as UISwitch:            style(v, p)
        default: break
        }
        for sub in view.subviews { restyle(sub, p) }
    }

    private static func style(_ bar: UINavigationBar, _ p: Palette?) {
        bar.titleTextAttributes = p.map { [.foregroundColor: $0.label] }
        bar.largeTitleTextAttributes = p.map { [.foregroundColor: $0.label] }
    }

    private static func style(_ seg: UISegmentedControl, _ p: Palette?) {
        for state in [UIControl.State.normal, .selected] {
            seg.setTitleTextAttributes(p.map { [.foregroundColor: $0.label] }, for: state)
        }
    }

    // Takes effect on the pre-iOS 26 bar only; the glass bar ignores item
    // colors (ContentView pre-colors the icons instead).
    private static func style(_ bar: UITabBar, _ p: Palette?) {
        bar.unselectedItemTintColor = p?.label2
        let a = UITabBarAppearance()
        a.configureWithDefaultBackground()
        if let p {
            for layout in [a.stackedLayoutAppearance, a.inlineLayoutAppearance, a.compactInlineLayoutAppearance] {
                layout.normal.iconColor = p.label2
                layout.normal.titleTextAttributes = [.foregroundColor: p.label2]
            }
        }
        bar.standardAppearance = a
        // nil restores the system's transparent scroll-edge look.
        bar.scrollEdgeAppearance = p == nil ? nil : a
    }

    private static func style(_ slider: UISlider, _ p: Palette?) {
        slider.thumbTintColor = p?.label
    }

    // Dark knob: a red one vanishes on the red "on" track.
    private static func style(_ toggle: UISwitch, _ p: Palette?) {
        toggle.thumbTintColor = p?.bg
    }
}
