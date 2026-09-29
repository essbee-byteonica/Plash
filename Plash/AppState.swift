import SwiftUI

@MainActor
final class AppState: ObservableObject {
	static let shared = AppState()

	var cancellables = Set<AnyCancellable>()

	let menu = SSMenu()
	let powerSourceWatcher = PowerSourceWatcher()

	private(set) lazy var statusItem = with(NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)) {
		$0.isVisible = true
		$0.behavior = [.removalAllowed, .terminationOnRemoval]
		$0.menu = menu
		$0.button!.image = .menuBarIcon
		$0.button!.setAccessibilityTitle(SSApp.name)
	}

	private(set) lazy var statusItemButton = statusItem.button!

	private(set) lazy var webViewController = with(WebViewController()) {
		$0.websiteID = primaryWebsiteID
	}

	/**
	The website assigned to the display the main window is on. `nil` means the current website.
	*/
	var primaryWebsiteID: UUID? {
		Display.primary.flatMap { Defaults[.displayWebsites][$0.id.uuidString] }
	}

	private(set) lazy var desktopWindow = with(DesktopWindow(display: Display.primary)) {
		$0.contentView = webViewController.webView
		$0.contentView?.isHidden = true
	}

	/**
	Windows for the other displays, keyed by display ID. Each shows its own website.
	*/
	private(set) var extraScreens = [UUID: ExtraScreen]()

	private var allWindows: [DesktopWindow] {
		[desktopWindow] + extraScreens.values.map(\.window)
	}

	var isBrowsingMode = false {
		didSet {
			guard isEnabled else {
				return
			}

			forEachVisibleWindow { $0.isInteractive = isBrowsingMode }
			applyOpacity()
			resetTimer()
		}
	}

	var isEnabled = true {
		didSet {
			resetTimer()
			statusItemButton.appearsDisabled = !isEnabled

			rebuildExtraScreens()

			if isEnabled {
				updatePrimaryWindow()
				loadUserURL()
			} else {
				// TODO: Properly unload the web view instead of just clearing and hiding it.
				desktopWindow.orderOut(self)
				loadURL("about:blank")
			}
		}
	}

	var isScreenLocked = false

	var isManuallyDisabled = false {
		didSet {
			setEnabledStatus()
		}
	}

	var reloadTimers = [Timer]()

	var webViewError: Error? {
		didSet {
			if let webViewError {
				statusItemButton.toolTip = "Error: \(webViewError.localizedDescription)"

				// TODO: There's a macOS bug that makes it black instead of a color.
//				statusItemButton.contentTintColor = .systemRed

				// TODO: Also present the error when the user just added it from the input box as then it's also "interactive".
				if
					isBrowsingMode,
					!webViewError.localizedDescription.contains("No internet connection")
				{
					webViewError.presentAsModal()
				}

				return
			}

			statusItemButton.contentTintColor = nil
		}
	}

	private init() {
		DispatchQueue.main.async { [self] in
			didLaunch()
		}
	}

	private func didLaunch() {
		// Before per-display settings, the "Show on" display always showed the current website.
		SSApp.runOnce(identifier: "migrateToPerDisplayWebsites") {
			guard let website = WebsitesController.shared.current else {
				return
			}

			// If that display isn't connected right now, the main display shows it instead, like before.
			let oldDisplay = Defaults[.display]
			let displays = [oldDisplay, oldDisplay?.isConnected == false || oldDisplay == nil ? Display.main : nil].compactMap { $0 }

			for display in displays where Defaults[.displayWebsites][display.id.uuidString] == nil {
				Defaults[.displayWebsites][display.id.uuidString] = website.id
			}
		}

		_ = statusItemButton
		_ = desktopWindow
		setUpEvents()
		showWelcomeScreenIfNeeded()

		#if DEBUG
//		SSApp.showSettingsWindow()
//		Constants.openWebsitesWindow()
		#endif
	}

	func handleMenuBarIcon() {
		statusItem.isVisible = true

		delay(.seconds(5)) { [self] in
			guard Defaults[.hideMenuBarIcon] else {
				return
			}

			statusItem.isVisible = false
		}
	}

	func handleAppReopen() {
		handleMenuBarIcon()
	}

	func setEnabledStatus() {
		isEnabled = !isManuallyDisabled && !isScreenLocked && !(Defaults[.deactivateOnBattery] && powerSourceWatcher?.powerSource.isUsingBattery == true)
	}

	/**
	One reload timer per display, each using the display's own interval or else the global one.
	*/
	func resetTimer() {
		reloadTimers.forEach { $0.invalidate() }
		reloadTimers = []

		guard
			isEnabled,
			!isBrowsingMode
		else {
			return
		}

		func interval(for id: UUID?) -> Double? {
			guard let seconds = id.flatMap({ Defaults[.displayReloadInterval][$0.uuidString] }) else {
				return Defaults[.reloadInterval]
			}

			return seconds > 0 ? seconds : nil
		}

		func schedule(_ interval: Double?, _ action: @escaping @MainActor () -> Void) {
			guard let interval else {
				return
			}

			reloadTimers.append(Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
				Task { @MainActor in
					action()
				}
			})
		}

		// We always load the website the user specified in case it's a redirect that may change on each call.
		if let primaryID = Display.primary?.id {
			schedule(interval(for: primaryID)) { [self] in
				loadURL(webViewController.website?.url)
			}
		}

		for (id, screen) in extraScreens {
			schedule(interval(for: id)) { [weak screen] in
				screen?.load()
			}
		}
	}

	func recreateWebView() {
		webViewController.websiteID = primaryWebsiteID
		webViewController.recreateWebView()
		desktopWindow.contentView = webViewController.webView
	}

	/**
	Moves the main window to its display, or hides it when no display has a website.
	*/
	func updatePrimaryWindow() {
		guard
			isEnabled,
			let display = Display.primary
		else {
			desktopWindow.orderOut(self)
			return
		}

		desktopWindow.targetDisplay = display
		desktopWindow.orderFront(self)
	}

	func recreateWebViewAndReload() {
		updatePrimaryWindow()
		recreateWebView()
		rebuildExtraScreens()
		loadUserURL()
	}

	/**
	Recreates the extra display windows from the `displayWebsites` setting. Doesn't load the pages.
	*/
	func rebuildExtraScreens() {
		for screen in extraScreens.values {
			screen.window.orderOut(self)
			screen.window.contentView = nil
		}

		extraScreens = [:]

		guard isEnabled else {
			return
		}

		let primaryID = Display.primary?.id

		for display in Display.all where display.id != primaryID {
			guard
				let websiteID = Defaults[.displayWebsites][display.id.uuidString],
				WebsitesController.shared.all[id: websiteID] != nil
			else {
				continue
			}

			let screen = ExtraScreen(display: display, websiteID: websiteID)
			screen.window.collectionBehavior.toggleExistence(.canJoinAllSpaces, shouldExist: Defaults[.showOnAllSpaces])
			screen.window.isInteractive = isBrowsingMode
			screen.window.orderFront(self)
			extraScreens[display.id] = screen
		}

		applyOpacity()
		resetTimer()
	}

	/**
	Sets the opacity of each display window. Browsing mode always uses full opacity.
	*/
	func applyOpacity() {
		func opacity(for id: UUID?) -> Double {
			id.flatMap { Defaults[.displayOpacity][$0.uuidString] } ?? Defaults[.opacity]
		}

		desktopWindow.alphaValue = isBrowsingMode ? 1 : opacity(for: Display.primary?.id)

		for (id, screen) in extraScreens {
			screen.window.alphaValue = isBrowsingMode ? 1 : opacity(for: id)
		}
	}

	/**
	Applies a change to every display window.
	*/
	func forEachWindow(_ body: (DesktopWindow) -> Void) {
		allWindows.forEach(body)
	}

	/**
	Like `forEachWindow`, but skips the main window while it's hidden because no display has a website.
	*/
	func forEachVisibleWindow(_ body: (DesktopWindow) -> Void) {
		(Display.primary == nil ? Array(extraScreens.values.map(\.window)) : allWindows).forEach(body)
	}

	func reloadWebsite() {
		// We always load the website the user specified in case it's a redirect that may change on each call.
		loadUserURL()

//		webViewController.reloadCurrentPageFromOrigin()
	}

	func loadUserURL() {
		guard isEnabled else {
			return
		}

		if Display.primary != nil {
			loadURL(webViewController.website?.url)
		}

		extraScreens.values.forEach { $0.load() }
	}

	func toggleBrowsingMode() {
		Defaults[.isBrowsingMode].toggle()
	}

	func loadURL(_ url: URL?) {
		webViewError = nil

		guard
			var url,
			url.isValid
		else {
			return
		}

		do {
			url = try replacePlaceholders(of: url) ?? url
		} catch {
			error.presentAsModal()
			return
		}

		webViewController.loadURL(url)

		// TODO: Add a callback to `loadURL` when it's done loading instead.
		// TODO: Fade in the web view.
		delay(.seconds(1)) { [self] in
			desktopWindow.contentView?.isHidden = false
		}
	}

	/**
	Replaces app-specific placeholder strings in the given URL with a corresponding value.
	*/
	func replacePlaceholders(of url: URL, screen: NSScreen? = nil) throws -> URL? {
		// Here we swap out `[[screenWidth]]` and `[[screenHeight]]` for their actual values.
		// We proceed only if we have an `NSScreen` to work with.
		guard let screen = screen ?? desktopWindow.targetDisplay?.screen ?? .main else {
			return nil
		}

		return try url
			.replacingPlaceholder("[[screenWidth]]", with: String(format: "%.0f", screen.frameWithoutStatusBar.width))
			.replacingPlaceholder("[[screenHeight]]", with: String(format: "%.0f", screen.frameWithoutStatusBar.height))
	}
}

/**
A desktop window and web view for one additional display.
*/
@MainActor
final class ExtraScreen {
	let window: DesktopWindow
	let controller = WebViewController()

	init(display: Display, websiteID: UUID) {
		controller.websiteID = websiteID
		window = DesktopWindow(display: display)
		window.contentView = controller.webView
		window.contentView?.isHidden = true
	}

	func load() {
		guard
			let url = controller.websiteID.flatMap({ WebsitesController.shared.all[id: $0] })?.url,
			url.isValid
		else {
			return
		}

		do {
			controller.loadURL(try AppState.shared.replacePlaceholders(of: url, screen: window.targetDisplay?.screen) ?? url)
		} catch {
			error.presentAsModal()
			return
		}

		delay(.seconds(1)) { [weak self] in
			self?.window.contentView?.isHidden = false
		}
	}
}

extension Display {
	/**
	The display the main window (and the app's menu, tooltip, etc.) belongs to: the first connected display that has a website.

	Doesn't touch `desktopWindow` as that depends on the web view.
	*/
	static var primary: Self? {
		let assignments = Defaults[.displayWebsites]
		return all.first { assignments[$0.id.uuidString] != nil }
	}
}
