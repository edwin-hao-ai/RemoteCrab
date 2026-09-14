import CoreGraphics
import SwiftUI

/// RemoteCrab spacing scale — 4pt base, Apple's preferred rhythm.
///
/// All UI spacing should come from these tokens. Using arbitrary
/// numbers (`padding: 13`) creates inconsistency and makes later
/// adjustments painful.
public enum IBSpace {

    case xxs  //  2pt
    case xs   //  4pt
    case s    //  8pt
    case m    // 12pt
    case l    // 16pt
    case xl   // 24pt
    case xxl  // 32pt
    case xxxl // 40pt
    case huge // 48pt

    public var pt: CGFloat {
        switch self {
        case .xxs:  return 2
        case .xs:   return 4
        case .s:    return 8
        case .m:    return 12
        case .l:    return 16
        case .xl:   return 24
        case .xxl:  return 32
        case .xxxl: return 40
        case .huge: return 48
        }
    }
}

/// RemoteCrab corner radius scale.
///
/// Apple Liquid Glass panels use generous corner radii — typically
/// 12pt for cards, 16-20pt for hero panels, continuous (squircle)
/// shapes for system elements.
public enum IBRadius {

    case pill      // perfect circle for small elements
    case xs        //  4pt — chips
    case s         //  6pt — buttons
    case m         // 10pt — buttons / cards
    case l         // 14pt — cards
    case xl        // 18pt — hero panels
    case xxl       // 24pt — overlays
    case continuous // squircle (Apple's preferred corner)

    public var pt: CGFloat {
        switch self {
        case .pill:       return .infinity
        case .xs:         return 4
        case .s:          return 6
        case .m:          return 10
        case .l:          return 14
        case .xl:         return 18
        case .xxl:        return 24
        case .continuous: return 16
        }
    }

    /// Continuous corner style — Apple's squircle.
    public var style: RoundedCornerStyle {
        switch self {
        case .continuous: return .continuous
        default:          return .continuous
        }
    }
}