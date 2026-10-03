//
//  LyricsWindowDockCoordinator.swift
//  Me2Tune
//
//  歌词窗口吸附联动协调器 - 支持靠近磁吸停靠与主面板父子窗口同步移动
//

import AppKit
import OSLog

private let logger = Logger.lyrics

@MainActor
final class LyricsWindowDockCoordinator: NSObject {
    weak var mainWindow: NSWindow?
    weak var lyricsWindow: NSWindow?
    
    private(set) var isDocked = false
    
    enum DockEdge {
        case left
        case right
    }
    private(set) var dockEdge: DockEdge = .right
    
    /// 吸附阈值（像素距离小于该值时触发磁吸）
    private let snapThreshold: CGFloat = 22.0
    /// 脱离阈值（像素位移大于该值时触发解绑，需大于吸附阈值以形成防抖滞后区间）
    private let detachThreshold: CGFloat = 30.0
    
    /// 吸附时在 Y 轴上的相对偏移量（通常为 0，即顶部对齐）
    private var dockedOffsetY: CGFloat = 0.0
    
    private var resizeObserver: Any?
    
    // MARK: - Lifecycle
    
    init(mainWindow: NSWindow? = nil, lyricsWindow: NSWindow? = nil) {
        self.mainWindow = mainWindow
        self.lyricsWindow = lyricsWindow
        super.init()
        
        setupMainWindowObservers()
    }
    
    func configure(mainWindow: NSWindow?, lyricsWindow: NSWindow?) {
        cleanupObservers()
        self.mainWindow = mainWindow
        self.lyricsWindow = lyricsWindow
        setupMainWindowObservers()
    }
    
    // MARK: - Frame Interception (Called from LyricsWindow.setFrameOrigin)
    
    func targetOrigin(for proposedOrigin: NSPoint, windowSize: NSSize) -> NSPoint {
        guard let main = mainWindow, main.isVisible, !main.isMiniaturized else {
            if isDocked {
                undock()
            }
            return proposedOrigin
        }
        
        let mFrame = main.frame
        let lWidth = windowSize.width
        let lHeight = windowSize.height
        
        if isDocked {
            // 已吸附状态：检测是否被拖拽脱离
            let expectedX = (dockEdge == .right) ? mFrame.maxX : (mFrame.minX - lWidth)
            let expectedY = mFrame.maxY - lHeight + dockedOffsetY
            
            let deltaX = proposedOrigin.x - expectedX
            let deltaY = proposedOrigin.y - expectedY
            let dist = hypot(deltaX, deltaY)
            
            if dist > detachThreshold {
                // 拖拽距离超过脱离阈值，解除吸附
                undock()
                return proposedOrigin
            } else {
                // 仍处于吸附防抖范围，磁吸保持锁定在吸附位置
                return NSPoint(x: expectedX, y: expectedY)
            }
        } else {
            // 未吸附状态：检测是否靠近主窗口边缘
            let verticalOverlap = (proposedOrigin.y + lHeight > mFrame.minY + 40) && (proposedOrigin.y < mFrame.maxY - 40)
            guard verticalOverlap else { return proposedOrigin }
            
            let distRight = abs(proposedOrigin.x - mFrame.maxX)
            let distLeft = abs((proposedOrigin.x + lWidth) - mFrame.minX)
            let distTop = abs((proposedOrigin.y + lHeight) - mFrame.maxY)
            let distBottom = abs(proposedOrigin.y - mFrame.minY)
            
            // 判定垂直对齐吸附目标（优先顶部对齐，其次底部对齐，否则保持当前 Y）
            let snapY: CGFloat
            if distTop <= snapThreshold {
                snapY = mFrame.maxY - lHeight
            } else if distBottom <= snapThreshold {
                snapY = mFrame.minY
            } else {
                snapY = proposedOrigin.y
            }
            
            if distRight <= snapThreshold {
                dockedOffsetY = snapY - (mFrame.maxY - lHeight)
                dock(edge: .right)
                return NSPoint(x: mFrame.maxX, y: snapY)
            } else if distLeft <= snapThreshold {
                dockedOffsetY = snapY - (mFrame.maxY - lHeight)
                dock(edge: .left)
                return NSPoint(x: mFrame.minX - lWidth, y: snapY)
            }
            
            return proposedOrigin
        }
    }
    
    // MARK: - Docking Control
    
    func dock(edge: DockEdge) {
        guard !isDocked, let main = mainWindow, let lyrics = lyricsWindow else { return }
        dockEdge = edge
        isDocked = true
        main.addChildWindow(lyrics, ordered: .above)
        logger.info("🔗 Lyrics window docked to main window (\(edge == .right ? "right" : "left"))")
    }
    
    func undock() {
        guard isDocked, let main = mainWindow, let lyrics = lyricsWindow else { return }
        main.removeChildWindow(lyrics)
        isDocked = false
        
        // 恢复用户在设置中设定的置顶级别
        let alwaysOnTop = SettingsManager.shared.lyricsAlwaysOnTop
        lyrics.level = alwaysOnTop ? .floating : .normal
        
        logger.info("🔓 Lyrics window undocked from main window")
    }
    
    func cleanup() {
        if isDocked {
            undock()
        }
        cleanupObservers()
        mainWindow = nil
        lyricsWindow = nil
    }
    
    // MARK: - Main Window Observers
    
    private func setupMainWindowObservers() {
        cleanupObservers()
        guard let main = mainWindow else { return }
        
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: main,
            queue: .main
        ) { [weak self] _ in
            self?.handleMainWindowResized()
        }
    }
    
    private func cleanupObservers() {
        if let observer = resizeObserver {
            NotificationCenter.default.removeObserver(observer)
            resizeObserver = nil
        }
    }
    
    private func handleMainWindowResized() {
        guard isDocked, let main = mainWindow, let lyrics = lyricsWindow else { return }
        let mFrame = main.frame
        let lWidth = lyrics.frame.width
        let lHeight = lyrics.frame.height
        
        let newX = (dockEdge == .right) ? mFrame.maxX : (mFrame.minX - lWidth)
        let newY = mFrame.maxY - lHeight + dockedOffsetY
        lyrics.setFrameOrigin(NSPoint(x: newX, y: newY))
    }
}

// MARK: - Snappable Lyrics Window Subclass

final class LyricsWindow: NSWindow {
    weak var dockCoordinator: LyricsWindowDockCoordinator?
    
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let finalOrigin = dockCoordinator?.targetOrigin(for: newOrigin, windowSize: frame.size) ?? newOrigin
        super.setFrameOrigin(finalOrigin)
    }
}
