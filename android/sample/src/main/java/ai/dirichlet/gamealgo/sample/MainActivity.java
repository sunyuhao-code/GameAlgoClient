package ai.dirichlet.gamealgo.sample;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

import com.gamealgo.sdk.GameAlgoClient;

public final class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        TextView text = new TextView(this);
        text.setText("GameAlgo Android SDK loaded: " + GameAlgoClient.class.getSimpleName());
        setContentView(text);
    }
}
