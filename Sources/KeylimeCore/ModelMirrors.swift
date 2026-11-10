import Foundation

/// Where the model manifest and model files come from.
///
/// The manifest comes from Nest, with the GitHub models-v1 copy as the fallback. Each model's files come from the
/// model's own `base_urls` in the manifest (its Hugging Face repo, then Nest), then the manifest's top-level
/// `base_urls`, then `fallbackBases`.
public enum ModelMirrors {
    public static let nest = "https://autocorrect.mostlime.hackclub.app/autocorrect-android/"

    public static let manifestUrls = [
        nest + "manifest.json",
        "https://github.com/Mostlime12195/keylime-models/releases/download/models-v1/manifest.json",
    ]

    /// last resort when the manifest's own mirrors all fail
    public static let fallbackBases = [nest]

    /// A model's `base_urls` from its manifest entry (empty when it has none).
    public static func baseUrls(_ model: [String: Any]) -> [String] {
        (model["base_urls"] as? [String] ?? []).filter { !$0.isEmpty }
    }

    /// Mirrors in the order they're tried: the model's own, then the manifest's top-level ones, then the fallback, without repeats.
    public static func order(model: [String], top: [String], fallback: [String] = fallbackBases) -> [String] {
        var seen = Set<String>()
        return (model + top + fallback).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
