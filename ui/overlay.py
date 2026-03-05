import os
import AppKit
import Foundation
import WebKit

# Ensure performBlock_ runs even during menu tracking / modal panels
_ALL_MODES = [AppKit.NSDefaultRunLoopMode, AppKit.NSEventTrackingRunLoopMode]


class OverlayPanel:
    """Floating pill overlay using NSPanel + WKWebView. Does NOT steal focus."""

    _PANEL_WIDTH = 140
    _PANEL_HEIGHT = 40
    _BOTTOM_OFFSET = 80  # px from bottom of usable screen area
    _POP_OUT_MS = 200  # match CSS pop-out duration (180ms + margin)

    def __init__(self):
        self._panel = None
        self._webview = None
        self._visible = False
        self._hide_timer = None
        self._setup()

    def _setup(self):
        frame = AppKit.NSMakeRect(0, 0, self._PANEL_WIDTH, self._PANEL_HEIGHT)

        style = (
            AppKit.NSWindowStyleMaskNonactivatingPanel
            | AppKit.NSWindowStyleMaskTitled
            | AppKit.NSWindowStyleMaskFullSizeContentView
        )
        self._panel = AppKit.NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            frame, style, AppKit.NSBackingStoreBuffered, False
        )
        self._panel.setBecomesKeyOnlyIfNeeded_(True)
        self._panel.setLevel_(AppKit.NSFloatingWindowLevel)
        self._panel.setTitlebarAppearsTransparent_(True)
        self._panel.setTitleVisibility_(AppKit.NSWindowTitleHidden)
        self._panel.setMovableByWindowBackground_(False)
        self._panel.setHasShadow_(False)
        self._panel.setOpaque_(False)
        self._panel.setBackgroundColor_(AppKit.NSColor.clearColor())
        self._panel.setIgnoresMouseEvents_(True)
        self._panel.setAlphaValue_(1.0)
        self._panel.setCollectionBehavior_(
            AppKit.NSWindowCollectionBehaviorCanJoinAllSpaces
            | AppKit.NSWindowCollectionBehaviorStationary
            | AppKit.NSWindowCollectionBehaviorFullScreenAuxiliary
        )

        config = WebKit.WKWebViewConfiguration.alloc().init()
        content_view = self._panel.contentView()
        self._webview = WebKit.WKWebView.alloc().initWithFrame_configuration_(
            content_view.bounds(), config
        )
        self._webview.setAutoresizingMask_(
            AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable
        )
        self._webview.setValue_forKey_(False, "drawsBackground")

        html_path = os.path.join(os.path.dirname(__file__), "overlay.html")
        with open(html_path) as f:
            html = f.read()
        self._webview.loadHTMLString_baseURL_(html, None)
        content_view.addSubview_(self._webview)

    def _on_main(self, fn):
        if AppKit.NSThread.isMainThread():
            fn()
        else:
            AppKit.NSRunLoop.mainRunLoop().performInModes_block_(_ALL_MODES, fn)

    def _reposition(self):
        screen = AppKit.NSScreen.mainScreen()
        if screen is None:
            return
        area = screen.visibleFrame()
        x = area.origin.x + (area.size.width - self._PANEL_WIDTH) / 2
        y = area.origin.y + self._BOTTOM_OFFSET
        self._panel.setFrameOrigin_(AppKit.NSMakePoint(x, y))

    def show(self):
        self._visible = True

        def _do():
            # Cancel any pending hide
            if self._hide_timer is not None:
                self._hide_timer.invalidate()
                self._hide_timer = None

            self._reposition()
            self._panel.orderFrontRegardless()

            # CSS handles the pop-in animation
            self._webview.evaluateJavaScript_completionHandler_(
                "setState('recording'); appear()", None
            )

        self._on_main(_do)

    def hide(self):
        if not self._visible:
            return
        self._visible = False

        def _do():
            # CSS handles the pop-out animation
            self._webview.evaluateJavaScript_completionHandler_(
                "disappear()", None
            )

            # orderOut after CSS animation completes
            def _order_out(timer):
                self._panel.orderOut_(None)
                self._hide_timer = None

            self._hide_timer = Foundation.NSTimer.timerWithTimeInterval_repeats_block_(
                self._POP_OUT_MS / 1000.0, False, _order_out
            )
            AppKit.NSRunLoop.mainRunLoop().addTimer_forMode_(
                self._hide_timer, Foundation.NSRunLoopCommonModes
            )

        self._on_main(_do)

    def set_state(self, state: str):
        """Set overlay state: 'recording' or 'processing'."""
        self._eval_js(f"setState('{state}')")

    def update_audio_level(self, level: float):
        if self._visible:
            self._eval_js(f"updateAudioLevelReal({level:.3f})")

    def _eval_js(self, js: str):
        if self._webview:
            if AppKit.NSThread.isMainThread():
                self._webview.evaluateJavaScript_completionHandler_(js, None)
            else:
                AppKit.NSRunLoop.mainRunLoop().performInModes_block_(
                    _ALL_MODES,
                    lambda: self._webview.evaluateJavaScript_completionHandler_(js, None),
                )

    @property
    def is_visible(self) -> bool:
        return self._visible
