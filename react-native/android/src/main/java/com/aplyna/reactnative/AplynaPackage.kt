package com.aplyna.reactnative

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

class AplynaPackage : BaseReactPackage() {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? = if (name == AplynaModule.NAME) AplynaModule(reactContext) else null
    override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
        mapOf(AplynaModule.NAME to ReactModuleInfo(AplynaModule.NAME, AplynaModule.NAME, false, false, false, true))
    }
}
