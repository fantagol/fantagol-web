package app.fantagol.android;

import android.os.Bundle;
import android.view.Window;

import androidx.annotation.Nullable;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowInsetsControllerCompat;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

    private void hideStatusBar() {
        Window window = getWindow();

        WindowInsetsControllerCompat controller =
                new WindowInsetsControllerCompat(
                        window,
                        window.getDecorView()
                );

        controller.setSystemBarsBehavior(
                WindowInsetsControllerCompat
                        .BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        );

        controller.hide(
                WindowInsetsCompat.Type.statusBars()
        );
    }

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        hideStatusBar();
    }

    @Override
    public void onResume() {
        super.onResume();
        hideStatusBar();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);

        if (hasFocus) {
            hideStatusBar();
        }
    }
}