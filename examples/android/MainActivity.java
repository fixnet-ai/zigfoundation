package com.example.zigfoundation;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;
import android.graphics.Color;

/**
 * zigfoundation Android 集成测试 Activity。
 *
 * 加载 libzigfoundation-example-android.so，
 * 调用 native runAllTests() 并显示结果。
 */
public class MainActivity extends Activity {
    static {
        System.loadLibrary("zigfoundation-example-android");
    }

    /** JNI native: 运行所有 13 模块测试，返回 true 表示全部通过 */
    private native boolean runAllTests();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        boolean passed = runAllTests();

        TextView tv = new TextView(this);
        tv.setTextSize(18);
        tv.setPadding(40, 80, 40, 40);

        if (passed) {
            tv.setText("✅ zigfoundation\nAll 13 modules PASSED\n\nCheck logcat for details:\nadb logcat -s zigfoundation:V");
            tv.setTextColor(Color.GREEN);
        } else {
            tv.setText("❌ zigfoundation\nSome tests FAILED\n\nCheck logcat for details:\nadb logcat -s zigfoundation:V");
            tv.setTextColor(Color.RED);
        }

        setContentView(tv);
    }
}
