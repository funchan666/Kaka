import React from 'react';
import {LogBox, StatusBar, StyleSheet, View} from 'react-native';
import KakaSurface from './native/KakaSurfaceNativeComponent';

if (__DEV__) {
  LogBox.ignoreLogs([/^Open debugger to view warnings\.$/]);
}

export default function App() {
  return (
    <View style={layout.frame}>
      <StatusBar barStyle="light-content" />
      <KakaSurface style={layout.frame} />
    </View>
  );
}

const layout = StyleSheet.create({
  frame: {flex: 1, backgroundColor: '#090a17'},
});
