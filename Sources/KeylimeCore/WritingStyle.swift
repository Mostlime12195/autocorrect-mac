import Engine
import Foundation

/// The style picker (Android Prefs.STYLES): which control token the model reads and which decode params the corrector
/// uses. casual keeps text as typed (no i -> I); formal adds capitals and commas while typing and full stops after a
/// pause (auto mode), and uses the formal cand-gen penalties.
public enum WritingStyle {
    public static let all = ["casual", "standard", "formal"]
    public static let defaultStyle = "standard"

    /// a saved value, or the default when nothing (or an unknown value) is saved
    public static func stored(_ raw: String?) -> String { raw.flatMap { all.contains($0) ? $0 : nil } ?? defaultStyle }

    /// the style in effect: models without style tokens (supports_style false) always decode as standard
    public static func effective(_ chosen: String, supportsStyle: Bool) -> String { supportsStyle ? stored(chosen) : defaultStyle }

    public static func label(_ s: String) -> String {
        switch s {
        case "casual": return "Casual"
        case "formal": return "Formal"
        default: return "Standard"
        }
    }

    /// a style's control token (style models only; nil = untagged context)
    public static func token(_ style: String, supportsStyle: Bool, tokens: [String: Int]) -> Int? { supportsStyle ? tokens[style] : nil }

    /// Android ModelSpec.paramsFor: style_params[style] (style models), else params; the formal style swaps in the
    /// formal kind penalties (params.pen_formal). The live manifest pins m2s to m2's lam 1.25 / bias 0 for every style
    /// (web/update_params.py PIN), so only the token and the penalties differ.
    public static func params(_ style: String, supportsStyle: Bool, params: DecodeParams, styleParams: [String: DecodeParams],
                              penFormal: [String: Double]) -> DecodeParams {
        var base = supportsStyle ? (styleParams[style] ?? params) : params
        if style == "formal" && !penFormal.isEmpty { base.pen = penFormal }
        return base
    }

    /// params.pen_formal of a manifest model entry
    public static func penFormal(_ model: [String: Any]) -> [String: Double] {
        ((model["params"] as? [String: Any])?["pen_formal"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
    }
}
