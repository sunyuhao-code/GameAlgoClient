package com.gamealgo.demo;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setGravity(Gravity.CENTER_VERTICAL);
        content.setPadding(dp(28), dp(28), dp(28), dp(28));
        content.setBackgroundColor(Color.rgb(244, 246, 245));

        TextView title = text("GameAlgo Android AAR", 24, Color.rgb(25, 32, 30));
        TextView status = text("Running packaged SDK check...", 16, Color.rgb(79, 91, 87));
        status.setPadding(0, dp(12), 0, 0);
        content.addView(title);
        content.addView(status);
        setContentView(content);

        new Thread(() -> {
            String result;
            try {
                result = DemoScenario.run();
            } catch (Exception error) {
                result = "FAILED\n" + error.getMessage();
            }
            String finalResult = result;
            runOnUiThread(() -> status.setText(finalResult));
        }, "gamealgo-demo").start();
    }

    private TextView text(String value, int sizeSp, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(sizeSp);
        view.setTextColor(color);
        return view;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
