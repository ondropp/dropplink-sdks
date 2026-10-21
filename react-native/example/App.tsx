import { useEffect, useState } from 'react';
import { Button, ScrollView, StyleSheet, Text, View } from 'react-native';
import {
  Dropplink,
  useDropplinkDeepLink,
  type Attribution,
  type DeepLink,
} from '@ondropp/dropplink-react-native';

// Dropplink.initialize runs in index.js, before this component mounts.

export default function App() {
  const [installId, setInstallId] = useState<string | null>(null);
  const [attribution, setAttribution] = useState<Attribution | null>(null);
  const [lastLink, setLastLink] = useState<DeepLink | null>(null);

  // Receives the deferred link after a fresh install and every App Link / Universal Link open.
  // A real app would navigate here, e.g. navigation.navigate(routeFor(link.path), link.params).
  useDropplinkDeepLink(setLastLink);

  // Forwards the launch URL and later Linking 'url' events to Dropplink.handleDeepLink.
  useEffect(() => Dropplink.listenToLinking(), []);

  const refresh = () => {
    Dropplink.getInstallId().then(setInstallId);
    Dropplink.getAttribution().then(setAttribution);
  };

  // Init runs in the background; attribution is null until the first /v1/init succeeds.
  useEffect(() => {
    refresh();
    const timer = setTimeout(refresh, 3000);
    return () => clearTimeout(timer);
  }, []);

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>Dropplink example</Text>

        <Text style={styles.label}>
          Install id (paste into Install debugger)
        </Text>
        <Text selectable style={styles.value}>
          {installId ?? '—'}
        </Text>

        <Text style={styles.label}>Attribution</Text>
        <Text selectable style={styles.value}>
          {attribution ? JSON.stringify(attribution, null, 2) : 'null'}
        </Text>

        <Text style={styles.label}>Last deep link</Text>
        <Text selectable style={styles.value}>
          {lastLink ? JSON.stringify(lastLink, null, 2) : 'none yet'}
        </Text>

        <Button title="Refresh" onPress={refresh} />

        {/* Events are queued natively and sent in the background; with debug on, Logcat / the
            Xcode console shows "Dropplink: track example_tap (queued, …)". */}
        <Button
          title="Track example_tap"
          onPress={() =>
            Dropplink.track('example_tap', { props: { screen: 'home' } })
          }
        />
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, paddingTop: 48 },
  content: { padding: 16, gap: 8 },
  title: { fontSize: 20, fontWeight: '600', marginBottom: 8 },
  label: { fontSize: 13, color: '#666', marginTop: 8 },
  value: { fontFamily: 'Menlo', fontSize: 13 },
});
