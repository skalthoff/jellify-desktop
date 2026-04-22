import SwiftUI

/// Playback preferences pane.
///
/// Exposes streaming quality, download quality, and preferred audio codec as
/// `@AppStorage`-backed pickers. These are UI-only knobs today — wiring into
/// the AVPlayer source URL and the Jellyfin transcoding profile lives in
/// follow-up work (see TODOs below). Persisting the selection now means the
/// eventual stream builder can read the current choice on day one without a
/// migration.
///
/// Design: matches the native Preferences aesthetic inside the Jellify shell.
/// Sections sit on `Theme.surface` with `Theme.border` outlines; labels use
/// 13pt `ink` weight 600, helper copy uses 11pt `ink3`. Option values are
/// stored as stable string raw values so the on-disk keys survive renames of
/// the display labels.
///
/// Preference keys (user-facing `@AppStorage`):
/// - `playback.streamingQuality`     — `PlaybackQuality`
/// - `playback.downloadQuality`      — `PlaybackQuality`
/// - `playback.preferredCodec`       — `PreferredAudioCodec`
///
/// Spec: `research/06-screen-specs.md` Issue 61 and GitHub issue #260.
struct PreferencesPlayback: View {
    @AppStorage("playback.streamingQuality") private var streamingQuality: PlaybackQuality = .automatic
    @AppStorage("playback.downloadQuality") private var downloadQuality: PlaybackQuality = .lossless
    @AppStorage("playback.preferredCodec") private var preferredCodec: PreferredAudioCodec = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Streaming",
                footnote: "Applies when playing over the network. \"Automatic\" lets Jellify pick based on your connection."
            ) {
                PreferenceRow(
                    label: "Quality",
                    help: streamingQuality.subtitle
                ) {
                    QualityPicker(selection: $streamingQuality)
                        .accessibilityLabel("Streaming quality")
                }
            }

            PreferenceSection(
                title: "Downloads",
                footnote: "Quality used for offline copies. Higher settings use more disk space."
            ) {
                PreferenceRow(
                    label: "Quality",
                    help: downloadQuality.subtitle
                ) {
                    QualityPicker(selection: $downloadQuality)
                        .accessibilityLabel("Download quality")
                }
            }

            PreferenceSection(
                title: "Audio Codec",
                footnote: "Preferred codec when transcoding is required. \"Automatic\" trusts the server."
            ) {
                PreferenceRow(
                    label: "Preferred codec",
                    help: preferredCodec.subtitle
                ) {
                    CodecPicker(selection: $preferredCodec)
                        .accessibilityLabel("Preferred audio codec")
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Playback")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Streaming and download quality, preferred audio codec.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }
}

// MARK: - Values

/// Quality tiers for streaming and downloads.
///
/// Raw values are stable user-defaults strings — do not rename without a
/// migration. The label/subtitle are display-only and safe to edit.
///
/// TODO(#260): wire these into the Jellyfin `PlaybackInfo` request. Each case
/// maps to a `DeviceProfile` + `MaxStreamingBitrate` pair the core sends to
/// `/Items/{id}/PlaybackInfo`. Original passthrough means omit transcoding
/// containers so the server returns a DirectStream URL.
enum PlaybackQuality: String, CaseIterable, Identifiable {
    case automatic
    case low
    case normal
    case lossless
    case original

    var id: String { rawValue }

    /// Short label used inside the segmented control / menu.
    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .low: return "Low"
        case .normal: return "Normal"
        case .lossless: return "Lossless"
        case .original: return "Original"
        }
    }

    /// Helper copy shown beneath the row. Mirrors the options from the spec.
    var subtitle: String {
        switch self {
        case .automatic: return "Picked by Jellify"
        case .low: return "128 kbps MP3"
        case .normal: return "320 kbps MP3"
        case .lossless: return "FLAC"
        case .original: return "Direct stream — no transcoding"
        }
    }
}

/// Preferred audio codec for transcoded playback.
///
/// TODO(#260): feed into the `DeviceProfile.TranscodingProfiles` list so the
/// server honors the user's preference before falling back to its default.
enum PreferredAudioCodec: String, CaseIterable, Identifiable {
    case automatic
    case aac
    case mp3
    case flac

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Auto"
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic: return "Trust server default"
        case .aac: return "Efficient, wide compatibility"
        case .mp3: return "Universal, lossy"
        case .flac: return "Lossless, larger files"
        }
    }
}

// MARK: - Pickers

/// Segmented control for the 5-option quality tiers. Uses a native
/// `SegmentedPickerStyle` so keyboard/accessibility comes for free, then
/// restyles the surround with theme tokens so it matches the rest of the
/// Preferences pane.
private struct QualityPicker: View {
    @Binding var selection: PlaybackQuality

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(PlaybackQuality.allCases) { q in
                Text(q.label).tag(q)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
    }
}

/// Inline menu picker for codec. Four short options fit comfortably in a
/// dropdown; a segmented control would feel noisy next to the quality row.
private struct CodecPicker: View {
    @Binding var selection: PreferredAudioCodec

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(PreferredAudioCodec.allCases) { c in
                Text(c.label).tag(c)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 140)
    }
}

// MARK: - Layout primitives

/// Grouped box containing a titled set of preference rows. Matches the native
/// "Preferences" grouping: 13pt semibold title, `surface` fill with `border`
/// outline, subdued 11pt footnote under the group.
struct PreferenceSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )

            if let footnote {
                Text(footnote)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A single row inside a `PreferenceSection`. Label on the left at 13pt/600,
/// control on the trailing edge, optional 11pt helper text underneath.
struct PreferenceRow<Control: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                Text(label)
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                control()
            }
            if let help {
                Text(help)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    PreferencesPlayback()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
