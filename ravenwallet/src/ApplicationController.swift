//
//  ApplicationController.swift
//  ravenwallet
//
//  Created by Adrian Corscadden on 2016-10-21.
//  Copyright © 2018 Ravenwallet Team. All rights reserved.
//

import UIKit
import Core
import UserNotifications

private let timeSinceLastExitKey = "TimeSinceLastExit"
private let shouldRequireLoginTimeoutKey = "ShouldRequireLoginTimeoutKey"

class ApplicationController : NSObject, Subscriber {

    let window = UIWindow()
    private var startFlowController: StartFlowPresenter?
    private var modalPresenter: ModalPresenter?
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .light))
    private var walletManager: WalletManager?
    private var walletCoordinator: WalletCoordinator?
    private var exchangeUpdater: ExchangeUpdater?
    private var feeUpdater: FeeUpdater?
    
    fileprivate var application: UIApplication?
    private let watchSessionManager = PhoneWCSessionManager()
    private var urlController: URLController?
    private var defaultsUpdater: UserDefaultsUpdater?
    private var reachability = ReachabilityMonitor()
    private let noAuthApiClient = BRAPIClient(authenticator: NoAuthAuthenticator())
    private var fetchCompletionHandler: ((UIBackgroundFetchResult) -> Void)?
    private var launchURL: URL?
    private var hasPerformedWalletDependentInitialization = false
    private var didInitWallet = false

    override init() {
        super.init()
        guardProtected(queue: DispatchQueue.walletQueue) {
                self.initWallet(completion: self.didAttemptInitWallet)
        }
    }

    private func initWallet(completion: @escaping () -> Void) {
        let dispatchGroup = DispatchGroup()
        Store.state.currencies.forEach { currency in
            initWallet(currency: currency, dispatchGroup: dispatchGroup)
        }
        dispatchGroup.notify(queue: .main) {
            completion()
        }
    }

    private func initWallet(currency: CurrencyDef, dispatchGroup: DispatchGroup) {
        dispatchGroup.enter()
        guard let currency = currency as? Raven else { return }
        guard let walletManager = try? WalletManager(currency: currency, dbPath: currency.dbPath) else { return }
        self.walletManager = walletManager
        self.exchangeUpdater = ExchangeUpdater(currency: currency, walletManager: self.walletManager!)
        self.walletManager!.initWallet { success in
            guard success else {
                // always keep RVN wallet manager, even if not initialized, since it the primaryWalletManager and needed for onboarding
                if !currency.matches(Currencies.rvn) {
                    self.walletManager!.db?.close()
                    self.walletManager!.db?.delete()
                    //self.walletManagerOne = nil
                }
                dispatchGroup.leave()
                return
            }
            self.walletManager?.requestTxUpdate()//BMEX: show transaction list befor peerManager connect
            self.walletManager!.initPeerManager {
                self.walletManager!.peerManager?.connect()
                dispatchGroup.leave()
            }
        }
    }

    private func didAttemptInitWallet() {
        DispatchQueue.main.async {
            self.didInitWallet = true
            if !self.hasPerformedWalletDependentInitialization {
                self.didInitWalletManager()
            }
        }
    }

    func launch(application: UIApplication, options: [UIApplication.LaunchOptionsKey: Any]?) {
        self.application = application
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalNever)
        setup()
        handleLaunchOptions(options)
        reachability.didChange = { isReachable in
            if !isReachable {
                self.reachability.didChange = { isReachable in
                    if isReachable {
                        self.retryAfterIsReachable()
                    }
                }
            }
        }
        if !hasPerformedWalletDependentInitialization && didInitWallet {
            didInitWalletManager()
        }
    }

    private func setup() {
        setupDefaults()
        setupAppearance()
        setupRootViewController()
        window.makeKeyAndVisible()
        listenForPushNotificationRequest()
        offMainInitialization()
        
        Store.subscribe(self, name: .reinitWalletManager(nil), callback: {
            guard let trigger = $0 else { return }
            if case .reinitWalletManager(let callback) = trigger {
                if let callback = callback {
                    self.reinitWalletManager(callback: callback)
                }
            }
        })
    }
    
    private func reinitWalletManager(callback: @escaping () -> Void) {
        Store.perform(action: Reset())
        self.setup()
        
        DispatchQueue.walletQueue.async {
            self.walletManager!.resetForWipe()
            self.initWallet {
                DispatchQueue.main.async {
                    self.didInitWalletManager()
                    callback()
                }
            }
        }
    }

    func willEnterForeground() {
        guard !walletManager!.noWallet else { return }
        if shouldRequireLogin() {
            Store.perform(action: RequireLogin())
        }
        DispatchQueue.walletQueue.async {
            self.walletManager!.peerManager?.connect()
        }
        exchangeUpdater!.refresh(completion: {})
        feeUpdater!.refresh()
    }

    func retryAfterIsReachable() {
        guard !walletManager!.noWallet else { return }
        DispatchQueue.walletQueue.async {
            self.walletManager!.peerManager?.connect()
        }
        exchangeUpdater!.refresh(completion: {})
        feeUpdater!.refresh()
    }

    func didEnterBackground() {
        // disconnect synced peer managers
        Store.state.currencies.filter { $0.state.syncState == .success }.forEach { currency in
            DispatchQueue.walletQueue.async {
                self.walletManager!.peerManager?.disconnect()
            }
        }
        //Save the backgrounding time if the user is logged in
        if !Store.state.isLoginRequired {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timeSinceLastExitKey)
        }
    }
    
    func WillTerminate() {
    }

    func performFetch(_ completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        fetchCompletionHandler = completionHandler
    }

    func open(url: URL) -> Bool {
        if let urlController = urlController {
            return urlController.handleUrl(url)
        } else {
            launchURL = url
            return false
        }
    }

    private func didInitWalletManager() {
        guard let rootViewController = window.rootViewController as? RootNavigationController else { return }
        walletCoordinator = WalletCoordinator(walletManager: walletManager!)
        Store.perform(action: PinLength.set(walletManager!.pinLength))
        rootViewController.walletManager = walletManager
        if let homeScreen = rootViewController.viewControllers.first as? HomeScreenViewController {
            homeScreen.walletManager = walletManager
        }
        hasPerformedWalletDependentInitialization = true
        if modalPresenter != nil {
            Store.unsubscribe(modalPresenter!)
        }
        modalPresenter = ModalPresenter(walletManager: walletManager!, window: window, apiClient: noAuthApiClient)
        startFlowController = StartFlowPresenter(walletManager: walletManager!, rootViewController: rootViewController)
        
        feeUpdater = FeeUpdater(walletManager: walletManager!)

        defaultsUpdater = UserDefaultsUpdater(walletManager: walletManager!)
        urlController = URLController(walletManager: walletManager!)
        if let url = launchURL {
            _ = urlController?.handleUrl(url)
            launchURL = nil
        }

//        For when watch app launches app in background
        if walletManager!.noWallet {
            addWalletCreationListener()
            Store.perform(action: ShowStartFlow())
        } else {
            DispatchQueue.walletQueue.async {
                self.walletManager!.peerManager?.connect()
            }
            startDataFetchers()
            exchangeUpdater!.refresh {
                self.watchSessionManager.walletManager = self.walletManager
                self.watchSessionManager.rate = Currencies.rvn.state.currentRate
            }
        }
    }

    private func shouldRequireLogin() -> Bool {
        let then = UserDefaults.standard.double(forKey: timeSinceLastExitKey)
        let timeout = UserDefaults.standard.double(forKey: shouldRequireLoginTimeoutKey)
        let now = Date().timeIntervalSince1970
        return now - then > timeout
    }

    private func setupDefaults() {
        if UserDefaults.standard.object(forKey: shouldRequireLoginTimeoutKey) == nil {
            UserDefaults.standard.set(60.0*3.0, forKey: shouldRequireLoginTimeoutKey) //Default 3 min timeout
        }
    }

    private func setupAppearance() {
        UINavigationBar.appearance().titleTextAttributes = [NSAttributedString.Key.font: UIFont.header]
    }

    private func setupRootViewController() {
        let home = HomeScreenViewController(walletManager: walletManager)
        let nc = RootNavigationController()
        nc.navigationBar.isTranslucent = false
        nc.navigationBar.tintColor = .white
        nc.pushViewController(home, animated: false)
        
        home.didSelectCurrency = { currency in
            let accountViewController = AccountViewController(walletManager: self.walletManager!)
            nc.pushViewController(accountViewController, animated: true)
        }
        
        home.didSelectAsset = { asset in //BMEX
            Store.perform(action: RootModalActions.Present(modal: .selectAsset(asset: asset)))
        }
        
        home.didSelectShowMoreAsset = {
            let allAssetVC = AllAssetVC(didSelectAsset: home.didSelectAsset!)
            nc.pushViewController(allAssetVC, animated: true)
        }
        
        home.didTapCreateAsset = {
            Store.perform(action: RootModalActions.Present(modal: .createAsset(initialAddress: nil)))
         }
        
        home.didTapSupport = {
            self.modalPresenter?.presentFaq()
        }
        
        home.didTapSecurity = {
            self.modalPresenter?.presentSecurityCenter()
        }
        
        home.didTapAddressBook = { currency in
            Store.trigger(name: .selectAddressBook(.normal, nil))
        }
        
        home.didTapTutorial = {
            self.modalPresenter?.presentTutorial()
        }
        
        home.didTapSettings = {
            self.modalPresenter?.presentSettings()
        }
        
        //State restoration
        let accountViewController = AccountViewController(walletManager: walletManager!)
        nc.pushViewController(accountViewController, animated: true)
        
        window.rootViewController = nc
    }

    private func startDataFetchers() {
        feeUpdater!.refresh()
        defaultsUpdater?.refresh()
        exchangeUpdater!.refresh(completion: {
            self.watchSessionManager.rate = Currencies.rvn.state.currentRate
        })
    }

    /// Handles new wallet creation or recovery
//    private func addWalletCreationListener() {
//        Store.subscribe(self, name: .didCreateOrRecoverWallet, callback: { _ in
//            self.walletManagers.removeAll() // remove the empty wallet managers
//            DispatchQueue.walletQueue.async {
//                self.initWallet(completion: self.didInitWalletManager)
//            }
//        })
//    }

    /// Handles new wallet creation or recovery
    private func addWalletCreationListener() {
        Store.subscribe(self, name: .didCreateOrRecoverWallet, callback: { _ in
            DispatchQueue.walletQueue.async {
                self.walletManager!.initWallet { _ in
                    self.walletManager!.initPeerManager {
                        self.walletManager!.peerManager?.connect()
                        self.startDataFetchers()
                    }
                }
            }
        })
    }
    
    private func offMainInitialization() {
        DispatchQueue.global(qos: .background).async {
            let _ = Rate.symbolMap //Initialize currency symbol map
        }
    }

    private func handleLaunchOptions(_ options: [UIApplication.LaunchOptionsKey: Any]?) {
        if let url = options?[.url] as? URL {
            do {
                let file = try Data(contentsOf: url)
                if file.count > 0 {
                    Store.trigger(name: .openFile(file))
                }
            } catch let error {
                print("Could not open file at: \(url), error: \(error)")
            }
        }
    }

    // Todo: fix and uncomment
    func performBackgroundFetch() {
//        saveEvent("appController.performBackgroundFetch")
//        let group = DispatchGroup()
//        if let peerManager = walletManager?.peerManager, peerManager.syncProgress(fromStartHeight: peerManager.lastBlockHeight) < 1.0 {
//            group.enter()
//            store.lazySubscribe(self, selector: { $0.walletState.syncState != $1.walletState.syncState }, callback: { state in
//                if self.fetchCompletionHandler != nil {
//                    if state.walletState.syncState == .success {
//                        DispatchQueue.walletQueue.async {
//                            peerManager.disconnect()
//                            group.leave()
//                        }
//                    }
//                }
//            })
//        }
//
//        group.enter()
//        Async.parallel(callbacks: [
//            { self.exchangeUpdater?.refresh(completion: $0) },
//            { self.feeUpdater?.refresh(completion: $0) },
//            { self.walletManager?.apiClient?.events?.sync(completion: $0) },
//            { self.walletManager?.apiClient?.updateFeatureFlags(); $0() }
//            ], completion: {
//                group.leave()
//        })
//
//        DispatchQueue.global(qos: .utility).async {
//            if group.wait(timeout: .now() + 25.0) == .timedOut {
//                self.saveEvent("appController.backgroundFetchFailed")
//                self.fetchCompletionHandler?(.failed)
//            } else {
//                self.saveEvent("appController.backgroundFetchNewData")
//                self.fetchCompletionHandler?(.newData)
//            }
//            self.fetchCompletionHandler = nil
//        }
    }

    func willResignActive() {
        applyBlurEffect()
        guard !Store.state.isPushNotificationsEnabled else { return }
        guard let pushToken = UserDefaults.pushToken else { return }
        walletManager!.apiClient?.deletePushNotificationToken(pushToken)
    }
    
    func didBecomeActive() {
        removeBlurEffect()
    }
    
    private func applyBlurEffect() {
        guard !Store.state.isLoginRequired && !Store.state.isPromptingBiometrics else { return }
        blurView.alpha = 1.0
        blurView.frame = window.frame
        window.addSubview(blurView)
    }
    
    private func removeBlurEffect() {
        let duration = Store.state.isLoginRequired ? 0.4 : 0.1 // keep content hidden if lock screen about to appear on top
        UIView.animate(withDuration: duration, animations: {
            self.blurView.alpha = 0.0
        }, completion: { _ in
            self.blurView.removeFromSuperview()
        })
    }
}

//MARK: - Push notifications
extension ApplicationController : UNUserNotificationCenterDelegate {
    func listenForPushNotificationRequest() {
        Store.subscribe(self, name: .registerForPushNotificationToken, callback: { _ in
            // BMEX *** UIUserNotificationSettings is Deprecated ****
            //let settings = UIUserNotificationSettings(types: [.badge, .sound, .alert], categories: nil)
            //self.application?.registerUserNotificationSettings(settings)
            // *** use UNUserNotificationCenter ***
            let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
            UNUserNotificationCenter.current().requestAuthorization(
                options: authOptions,
                completionHandler: {_, _ in })
            UNUserNotificationCenter.current().delegate = self
            self.application?.registerForRemoteNotifications()
        })
    }

    /* BMEX UIUserNotificationSettings was deprecated
     func application(_ application: UIApplication, didRegister notificationSettings: UIUserNotificationSettings) {
        if !notificationSettings.types.isEmpty {
            application.registerForRemoteNotifications()
        }
    }
     */

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
//        guard let apiClient = walletManager?.apiClient else { return }
//        guard UserDefaults.pushToken != deviceToken else { return }
//        UserDefaults.pushToken = deviceToken
//        apiClient.savePushNotificationToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("didFailToRegisterForRemoteNotification: \(error)")
    }
}
