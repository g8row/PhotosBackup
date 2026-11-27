import Photos
import SwiftUI
import UIKit

struct OnboardingView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var probe: AccountConnector
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore
    @Environment(\.openURL) private var openURL

    @State private var step = 0
    @State private var appeared = false
    @State private var showingConnect = false

    private let gpmcURL = URL(string: "https://github.com/xob0t/gpmc")!
    private let pageCount = 7

    var body: some View {
        ZStack {
            BackupTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                TabView(selection: $step) {
                    welcome.tag(0)
                    connectAccount.tag(1)
                    connectionCheck.tag(2)
                    permission.tag(3)
                    chooseFolders.tag(4)
                    connectionPreference.tag(5)
                    complete.tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: step)
            }
        }
        .fullScreenCover(isPresented: $showingConnect) {
            AccountConnectView(
                onCaptured: { token in
                    showingConnect = false
                    withAnimation { step = 2 }
                    Task { await probe.ingestWebToken(token) }
                },
                onCancel: { showingConnect = false }
            )
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            albums.refreshInBackground()
        }
        .onChange(of: account.status) { status in
            guard step == 2, status.isUsable else { return }
            advanceAfterVerifiedConnection()
        }
        .onChange(of: log.steps) { _ in
            guard step == 2 else { return }
            advanceAfterVerifiedConnection()
        }
    }

    private var topBar: some View {
        HStack {
            if step > 0 {
                Button { withAnimation { step -= 1 } } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? BackupTheme.blue : Color.secondary.opacity(0.22))
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            Spacer()
            Color.clear.frame(width: 44, height: 34)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var welcome: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(BackupTheme.blue.opacity(0.08)).frame(width: 230, height: 230)
                    Circle().fill(BackupTheme.blue.opacity(0.10)).frame(width: 172, height: 172)
                    AppMark(size: 112)
                }
            ),
            eyebrow: "PHOTOS BACKUP",
            title: "Your memories, safely backed up",
            message: "Choose the albums that matter. Photos Backup keeps them protected in your Google Photos library.",
            primaryTitle: "Get Started",
            primaryAction: next,
            credit: "Built with GPMC by xob0t"
        )
    }

    private var permission: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(Color.pink.opacity(0.10)).frame(width: 220, height: 220)
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 78, weight: .medium))
                        .foregroundStyle(.pink, .purple)
                }
            ),
            eyebrow: "YOUR LIBRARY",
            title: "Choose what to protect",
            message: "Allow photo access so you can pick albums and back up individual photos. Your library stays private on this device.",
            primaryTitle: permissionButtonTitle,
            primaryAction: {
                Task {
                    if albums.authorization == .notDetermined {
                        await albums.requestAccess()
                        if albums.canRead { next() }
                    } else if albums.canRead {
                        next()
                    } else {
                        openAppSettings()
                    }
                }
            },
            secondaryTitle: albums.authorization == .denied || albums.authorization == .restricted ? "Continue without access" : nil,
            secondaryAction: next
        )
    }

    private var connectAccount: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(BackupTheme.blue.opacity(0.10)).frame(width: 220, height: 220)
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 74, weight: .medium))
                        .foregroundStyle(BackupTheme.blue)
                }
            ),
            eyebrow: "CONNECT YOUR ACCOUNT",
            title: "Sign in with Google",
            message: "Connect your Google account to back up to Google Photos. Sign-in opens in a secure in-app window — sign in, then tap I agree.",
            primaryTitle: "Connect Google Account",
            primaryAction: { showingConnect = true }
        )
    }

    private var connectionCheck: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 28)
                    ZStack {
                        Circle().fill(connectionTint.opacity(0.10)).frame(width: 220, height: 220)
                        Circle().stroke(connectionTint.opacity(0.18), lineWidth: 8).frame(width: 154, height: 154)
                        if probe.running {
                            ProgressView().controlSize(.large).tint(connectionTint).scaleEffect(1.35)
                        } else {
                            Image(systemName: connectionVerified ? "checkmark.icloud.fill" : connectionFailed ? "exclamationmark.icloud.fill" : "iphone.and.arrow.forward")
                                .font(.system(size: 72, weight: .medium)).foregroundStyle(connectionTint)
                        }
                    }
                    Spacer(minLength: 28)
                    Text(connectionEyebrow).font(.caption.weight(.bold)).tracking(1.3).foregroundStyle(connectionTint)
                    Text(connectionTitle).font(.largeTitle.bold()).multilineTextAlignment(.center).padding(.top, 9)
                    Text(connectionMessage).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3).padding(.top, 12)
                    Spacer(minLength: 28)
                    if !connectionVerified {
                        Button(probe.running ? "Verifying…" : (connectionFailed ? "Try Again" : "Check Again")) {
                            if connectionFailed { showingConnect = true } else { verifyConnection() }
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(probe.running)
                        if !probe.running {
                            Button("Connect a Different Account") { showingConnect = true }
                                .font(.headline)
                                .frame(minHeight: 44)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .frame(minHeight: geometry.size.height)
            }
            .hiddenScrollIndicators()
        }
        .onAppear { verifyConnection() }
    }

    private var chooseFolders: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                Text("CHOOSE ALBUMS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(BackupTheme.blue)
                Text("What should we back up?").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text("You can change this anytime in Albums.")
                    .font(.body).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Group {
                if albums.canRead {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(albums.albums.prefix(12)) { album in
                                AlbumSelectionRow(album: album, isSelected: preferences.selectedAlbumIDs.contains(album.id)) {
                                    preferences.toggle(albumID: album.id)
                                }
                            }
                        }
                        .padding(20)
                    }
                } else {
                    EmptyState(symbol: "photo.badge.exclamationmark", title: "Photo access is off", message: "You can choose albums later after allowing photo access in Settings.")
                    Spacer()
                }
            }

            VStack(spacing: 10) {
                Button(preferences.selectedAlbumIDs.isEmpty ? "Choose Later" : "Continue") { next() }
                    .buttonStyle(PrimaryButtonStyle())
                Text("\(preferences.selectedAlbumIDs.count) selected")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var connectionPreference: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 30)
                    FeatureIcon(symbol: "wifi", size: 76)
                    Text("When should we back up?")
                        .font(.largeTitle.bold()).multilineTextAlignment(.center).padding(.top, 24)
                    Text("Choose how Photos Backup uses your connection.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 10)

                    VStack(spacing: 12) {
                        ForEach(BackupConnection.allCases) { option in
                            Button { preferences.connection = option } label: {
                                HStack(spacing: 14) {
                                    FeatureIcon(symbol: option == .wifiOnly ? "wifi" : "antenna.radiowaves.left.and.right", size: 44)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.title).font(.headline).foregroundStyle(.primary)
                                        Text(option.detail).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: preferences.connection == option ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(preferences.connection == option ? BackupTheme.blue : .secondary)
                                }
                                .padding(16)
                                .background(BackupTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(preferences.connection == option ? BackupTheme.blue : .clear, lineWidth: 2))
                            }
                        }
                    }
                    .padding(.top, 28)

                    Toggle("Back up selected albums automatically", isOn: $preferences.automaticBackup)
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 22)
                    Spacer(minLength: 28)
                    Button("Continue") { next() }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(24)
                .frame(minHeight: geometry.size.height)
            }
            .hiddenScrollIndicators()
        }
    }

    private var complete: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(Color.green.opacity(0.11)).frame(width: 220, height: 220)
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 86, weight: .medium))
                        .foregroundStyle(.green)
                }
            ),
            eyebrow: "ALL SET",
            title: "Your backup is ready",
            message: completionMessage,
            primaryTitle: "Go to Photos Backup",
            primaryAction: finish
        )
    }

    private func onboardingPage(
        artwork: AnyView,
        eyebrow: String,
        title: String,
        message: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: @escaping () -> Void = {},
        credit: String? = nil
    ) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 28)
                    artwork
                    Spacer(minLength: 28)
                    Text(eyebrow).font(.caption.weight(.bold)).tracking(1.3).foregroundStyle(BackupTheme.blue)
                    Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center).padding(.top, 9)
                    Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3).padding(.top, 12)
                    Spacer(minLength: 28)
                    Button(primaryTitle, action: primaryAction).buttonStyle(PrimaryButtonStyle())
                    if let secondaryTitle {
                        Button(secondaryTitle, action: secondaryAction)
                            .font(.headline)
                            .frame(minHeight: 44)
                            .padding(.top, 8)
                    }
                    if let credit {
                        Link(credit, destination: gpmcURL)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .padding(.top, 4)
                            .accessibilityHint("Opens the GPMC project on GitHub")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .frame(minHeight: geometry.size.height)
            }
            .hiddenScrollIndicators()
        }
    }

    private var permissionButtonTitle: String {
        switch albums.authorization {
        case .authorized, .limited: return "Continue"
        case .denied, .restricted: return "Open Settings"
        default: return "Allow Photo Access"
        }
    }

    private var completionMessage: String {
        let count = preferences.selectedAlbumIDs.count
        return count == 0
            ? "Your account is connected. You can choose albums from the Albums tab."
            : "Your account is connected, and we’ll keep \(count) selected \(count == 1 ? "album" : "albums") protected."
    }

    private func next() { withAnimation { step = min(pageCount - 1, step + 1) } }
    private func finish() { preferences.completedOnboarding = true }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var connectionFailed: Bool {
        logState(ProbeLog.masterToken) == .failed || logState(ProbeLog.photosToken) == .failed || logState(ProbeLog.readAccess) == .failed
    }

    private var connectionVerified: Bool {
        guard account.status.isUsable else { return false }
        // A fresh handoff must pass the Photos read check. A restored account
        // has no in-memory exchange result, so its successful credential
        // restoration is sufficient and Settings still offers Verify.
        return probe.lastResult == nil || logState(ProbeLog.readAccess) == .passed
    }

    private var connectionTint: Color {
        if connectionVerified { return .green }
        if connectionFailed { return .orange }
        return BackupTheme.blue
    }

    private var connectionEyebrow: String {
        if connectionVerified { return "CONNECTION VERIFIED" }
        if connectionFailed { return "COULDN’T CONNECT" }
        return probe.running ? "VERIFYING ACCOUNT" : "WAITING TO CONNECT"
    }

    private var connectionTitle: String {
        if connectionVerified { return "You’re connected" }
        if connectionFailed { return "Let’s try that again" }
        return probe.running ? "Checking your account…" : "Finish connecting"
    }

    private var connectionMessage: String {
        if connectionVerified { return "Photos Backup verified your Google Photos account. You’re ready to continue." }
        if connectionFailed {
            return "We received the sign-in, but couldn’t verify it. Tap Try Again, sign in, and tap I agree."
        }
        return probe.running
            ? "We securely captured your sign-in and are verifying your Google Photos access."
            : "Sign in and tap I agree in the connect window. We’ll verify everything before continuing."
    }

    private func logState(_ id: String) -> ProbeStep.State? {
        probe.log.steps.first(where: { $0.id == id })?.state
    }

    private func verifyConnection() {
        if account.status.isUsable {
            Task { await account.verify() }
        }
    }

    private func advanceAfterVerifiedConnection() {
        guard connectionVerified else { return }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if step == 2, connectionVerified { withAnimation { step = 3 } }
        }
    }
}

struct AlbumSelectionRow: View {
    let album: PhotoAlbum
    let isSelected: Bool
    var backedUpCount: Int? = nil
    var eligibleCount: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                FeatureIcon(symbol: album.symbol, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(isSelected ? BackupTheme.blue : .secondary)
            }
            .padding(14)
            .background(BackupTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        let total = eligibleCount ?? album.count
        guard let backedUpCount else { return "\(total.formatted()) items" }
        if total == 0 { return "0 matching items" }
        if backedUpCount >= total { return "All \(total.formatted()) backed up" }
        return "\(backedUpCount.formatted()) of \(total.formatted()) backed up"
    }
}
