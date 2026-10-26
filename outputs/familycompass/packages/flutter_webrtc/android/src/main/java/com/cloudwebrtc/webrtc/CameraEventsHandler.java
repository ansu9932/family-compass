package com.cloudwebrtc.webrtc;

import android.util.Log;
import android.os.SystemClock;

import org.webrtc.CameraVideoCapturer;

class CameraEventsHandler implements CameraVideoCapturer.CameraEventsHandler {
    public enum CameraState {
        NEW,
        OPENING,
        OPENED,
        CLOSED,
        DISCONNECTED,
        ERROR,
        FREEZED
    }
    private final static String TAG = FlutterWebRTCPlugin.TAG;
    private volatile CameraState state = CameraState.NEW;

    public boolean waitForCameraOpen() {
        Log.d(TAG, "CameraEventsHandler.waitForCameraOpen");
        long deadline = SystemClock.elapsedRealtime() + 10000;
        while (state == CameraState.NEW || state == CameraState.OPENING) {
            if (SystemClock.elapsedRealtime() >= deadline) return false;
            try {
                Thread.sleep(10);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
        }
        return state == CameraState.OPENED;
    }

    public void waitForCameraClosed() {
        Log.d(TAG, "CameraEventsHandler.waitForCameraClosed");
        long deadline = SystemClock.elapsedRealtime() + 5000;
        while (state != CameraState.CLOSED && state != CameraState.ERROR && state != CameraState.DISCONNECTED) {
            if (SystemClock.elapsedRealtime() >= deadline) return;
            try {
                Thread.sleep(10);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    // Camera error handler - invoked when camera can not be opened
    // or any camera exception happens on camera thread.
    @Override
    public void onCameraError(String errorDescription) {
        Log.d(TAG, String.format("CameraEventsHandler.onCameraError: errorDescription=%s", errorDescription));
        state = CameraState.ERROR;
    }

    // Called when camera is disconnected.
    @Override
    public void onCameraDisconnected() {
        Log.d(TAG, "CameraEventsHandler.onCameraDisconnected");
        state = CameraState.DISCONNECTED;
    }

    // Invoked when camera stops receiving frames
    @Override
    public void onCameraFreezed(String errorDescription) {
        Log.d(TAG, String.format("CameraEventsHandler.onCameraFreezed: errorDescription=%s", errorDescription));
        state = CameraState.FREEZED;
    }

    // Callback invoked when camera is opening.
    @Override
    public void onCameraOpening(String cameraName) {
        Log.d(TAG, String.format("CameraEventsHandler.onCameraOpening: cameraName=%s", cameraName));
        state = CameraState.OPENING;
    }

    // Callback invoked when first camera frame is available after camera is opened.
    @Override
    public void onFirstFrameAvailable() {
        Log.d(TAG, "CameraEventsHandler.onFirstFrameAvailable");
        state = CameraState.OPENED;
    }

    // Callback invoked when camera closed.
    @Override
    public void onCameraClosed() {
        Log.d(TAG, "CameraEventsHandler.onFirstFrameAvailable");
        state = CameraState.CLOSED;
    }
}
