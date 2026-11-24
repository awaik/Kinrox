import Foundation

extension PlayerViewModel {
    /// Only expose the animation after mpv confirms the pause; preserve position and fullscreen.
    @discardableResult
    func startMatrix(completion: ((Bool) -> Void)? = nil) -> Bool {
        guard !isClosing, !isLoading else {
            completion?(false)
            return false
        }
        if screensaver == .matrix {
            completion?(true)
            return true
        }
        if let completion { screensaverStartCompletions.append(completion) }
        guard !isStartingScreensaver else { return true }
        isStartingScreensaver = true
        cancelEOFRefresh()
        isStartingHome = false
        setShowingHome(false)
        isShowingConnectPhone = false
        trackController.presentation = nil
        let preparation = UUID()
        screensaverPreparation = preparation
        if beforeStartingMatrix?({ [weak self] paused in
            guard let self, self.screensaverPreparation == preparation else { return }
            self.screensaverPreparation = nil
            if paused { _ = self.waitForMatrixPause() } else { self.stopScreensaver() }
        }) == true {
            return true
        }
        screensaverPreparation = nil
        return waitForMatrixPause()
    }

    private func waitForMatrixPause() -> Bool {
        if !hasMedia || (paused && requestedPause != false) {
            activateMatrix()
            return true
        }
        guard setPaused(true) else {
            stopScreensaver()
            return false
        }
        screensaverPauseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, !Task.isCancelled, self.isStartingScreensaver else { return }
            self.stopScreensaver()
            self.errorMessage = L10n.text("The movie could not be paused. Try again.")
        }
        return true
    }

    func activateMatrix() {
        screensaverPauseTask?.cancel()
        screensaverPauseTask = nil
        isStartingScreensaver = false
        screensaver = .matrix
        screensaverPresentation.start()
        let completions = takeScreensaverStartCompletions()
        notifyPlayback()
        for completion in completions { completion(true) }
    }

    @discardableResult
    func stopScreensaver() -> Bool {
        screensaverPauseTask?.cancel()
        screensaverPauseTask = nil
        let changed = isScreensaverEngaged
        screensaverPreparation = nil
        isStartingScreensaver = false
        screensaver = .off
        screensaverPresentation.stop()
        let completions = takeScreensaverStartCompletions()
        if changed { notifyPlayback() }
        for completion in completions { completion(false) }
        return true
    }

    private func takeScreensaverStartCompletions() -> [(Bool) -> Void] {
        let completions = screensaverStartCompletions
        screensaverStartCompletions.removeAll()
        return completions
    }
}
