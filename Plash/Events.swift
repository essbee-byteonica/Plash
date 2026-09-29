import Cocoa
import KeyboardShortcuts

extension AppState {
	func setUpEvents() {
		menu.onUpdate = { [self] in
			updateMenu()
		}

		webViewController.didLoadPublisher
			.convertToResult()
			.sink { [self] result in
				switch result {
				case .success:
					// Set the persisted zoom level.
					// This must be here as `webView.url` needs to have been set.
					let zoomLevel = webViewController.webView.zoomLevelWrapper
					if zoomLevel != 1 {
						webViewController.webView.zoomLevelWrapper = zoomLevel
					}

					statusItemButton.toolTip = webViewController.website?.tooltip
				case .failure(let error):
					webViewError = error
				}
			}
			.store(in: &cancellables)

		powerSourceWatcher?.didChangePublisher
			.sink { [self] _ in
				guard Defaults[.deactivateOnBattery] else {
					return
				}

				setEnabledStatus()
			}
			.store(in: &cancellables)

		SSEvents.deviceDidWake
			.sink { [self] in
				reloadWebsite()
			}
			.store(in: &cancellables)

		SSEvents.isScreenLocked
			.sink { [self] in
				isScreenLocked = $0
				setEnabledStatus()
			}
			.store(in: &cancellables)

		Defaults.publisher(.websites, options: [])
			.receive(on: DispatchQueue.main)
			.sink { [self] in
				resetTimer()

				// Drop display assignments that point to a deleted website.
				let websiteIDs = Set($0.newValue.map(\.id))
				let assignments = Defaults[.displayWebsites]
				let validAssignments = assignments.filter { websiteIDs.contains($0.value) }
				if validAssignments.count != assignments.count {
					Defaults[.displayWebsites] = validAssignments
				}

				recreateWebViewAndReload()

				// We never destroy the webview, so we have to make sure it's not in browsing mode when there are no websites.
				if $0.newValue.isEmpty {
					Defaults[.isBrowsingMode] = false
				}
			}
			.store(in: &cancellables)

		Defaults.publisher(.isBrowsingMode)
			.receive(on: DispatchQueue.main)
			.sink { [self] change in
				isBrowsingMode = change.newValue
			}
			.store(in: &cancellables)

		Defaults.publisher(.hideMenuBarIcon)
			.sink { [self] _ in
				handleMenuBarIcon()
			}
			.store(in: &cancellables)

		Defaults.publisher(.opacity)
			.sink { [self] change in
				forEachWindow { $0.alphaValue = isBrowsingMode ? 1 : change.newValue }
			}
			.store(in: &cancellables)

		Defaults.publisher(.reloadInterval)
			.sink { [self] _ in
				resetTimer()
			}
			.store(in: &cancellables)

		Defaults.publisher(.display, options: [])
			.sink { [self] change in
				desktopWindow.targetDisplay = change.newValue
				recreateWebViewAndReload()
			}
			.store(in: &cancellables)

		Defaults.publisher(.displayWebsites, options: [])
			.receive(on: DispatchQueue.main)
			.sink { [self] _ in
				recreateWebViewAndReload()
			}
			.store(in: &cancellables)

		// Displays getting connected or disconnected.
		NotificationCenter.default
			.publisher(for: NSApplication.didChangeScreenParametersNotification)
			.debounce(for: .seconds(1), scheduler: DispatchQueue.main)
			.sink { [self] _ in
				// Only touch the main web view if which website it should show changed.
				if webViewController.websiteID != primaryWebsiteID {
					recreateWebViewAndReload()
				} else {
					rebuildExtraScreens()
					extraScreens.values.forEach { $0.load() }
				}
			}
			.store(in: &cancellables)

		Defaults.publisher(.deactivateOnBattery)
			.sink { [self] _ in
				setEnabledStatus()
			}
			.store(in: &cancellables)

		Defaults.publisher(.showOnAllSpaces)
			.sink { [self] change in
				forEachWindow { $0.collectionBehavior.toggleExistence(.canJoinAllSpaces, shouldExist: change.newValue) }
			}
			.store(in: &cancellables)

		Defaults.publisher(.bringBrowsingModeToFront, options: [])
			.sink { [self] _ in
				forEachWindow { $0.isInteractive = $0.isInteractive }
			}
			.store(in: &cancellables)

		Defaults.publisher(.muteAudio, options: [])
			.receive(on: DispatchQueue.main)
			.sink { [self] _ in
				recreateWebViewAndReload()
			}
			.store(in: &cancellables)

		KeyboardShortcuts.onKeyUp(for: .toggleBrowsingMode) {
			Defaults[.isBrowsingMode].toggle()
		}

		KeyboardShortcuts.onKeyUp(for: .toggleEnabled) { [self] in
			isManuallyDisabled.toggle()
		}

		KeyboardShortcuts.onKeyUp(for: .reload) { [self] in
			reloadWebsite()
		}

		KeyboardShortcuts.onKeyUp(for: .nextWebsite) {
			WebsitesController.shared.makeNextCurrent()
		}

		KeyboardShortcuts.onKeyUp(for: .previousWebsite) {
			WebsitesController.shared.makePreviousCurrent()
		}

		KeyboardShortcuts.onKeyUp(for: .randomWebsite) {
			WebsitesController.shared.makeRandomCurrent()
		}
	}
}
