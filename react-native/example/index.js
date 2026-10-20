import { AppRegistry, Platform } from 'react-native';
import Config from 'react-native-config';
import { Dropplink } from '@ondropp/dropplink-react-native';
import App from './App';
import { name as appName } from './app.json';

// As early as possible, before any component mounts. Keys come from a git-ignored .env file
// via react-native-config; never hard-code them here.
// Each platform has its own SDK key.
Dropplink.initialize({
  keyId: Platform.select({
    ios: Config.DROPPLINK_IOS_KEY_ID,
    default: Config.DROPPLINK_ANDROID_KEY_ID,
  }),
  secret: Platform.select({
    ios: Config.DROPPLINK_IOS_SECRET,
    default: Config.DROPPLINK_ANDROID_SECRET,
  }),
  debug: __DEV__,
}).catch((e) => console.warn('Dropplink.initialize failed', e));

AppRegistry.registerComponent(appName, () => App);
