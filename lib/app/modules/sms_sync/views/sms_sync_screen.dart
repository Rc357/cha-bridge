import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../theme_controller.dart';
import '../../../widgets/chabridge_logo.dart';
import '../controllers/sms_sync_controller.dart';

class SmsSyncScreen extends StatefulWidget {
  const SmsSyncScreen({super.key});

  @override
  State<SmsSyncScreen> createState() => _SmsSyncScreenState();
}

class _SmsSyncScreenState extends State<SmsSyncScreen>
    with WidgetsBindingObserver {
  static const _dangerColor = Color(0xFF8A4B52);

  late final SmsSyncController controller;
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = Get.find<SmsSyncController>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.requestSyncPermissionsOnLogin();
      controller.handleScreenOpened();
      controller.pullFromFirebase(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.handleAppResumed();
      controller.refreshBatteryOptimizationStatus(silent: true);
      controller.pullFromFirebase(silent: true);
    }
  }

  Future<void> _showCreateInboxDialog(
    BuildContext context,
    SmsSyncController controller,
  ) async {
    var inboxName = '';
    var password = '';
    var usePassword = false;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Create Chat Inbox'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    onChanged: (value) => inboxName = value,
                    decoration: const InputDecoration(
                      labelText: 'Inbox name',
                      prefixIcon: Icon(Icons.forum_outlined),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Protect with password'),
                    value: usePassword,
                    onChanged: (value) => setState(() => usePassword = value),
                  ),
                  if (usePassword)
                    TextField(
                      obscureText: true,
                      onChanged: (value) => password = value,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final name = inboxName.trim();
                    final pass = usePassword ? password.trim() : '';
                    Navigator.of(context).pop();
                    await controller.createInbox(name, password: pass);
                  },
                  child: const Text('Create'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<String?> _showPasswordDialog(
    BuildContext context, {
    required String title,
    required String confirmLabel,
  }) async {
    var password = '';
    final result = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            obscureText: true,
            onChanged: (value) => password = value,
            decoration: const InputDecoration(
              labelText: 'Password',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(password.trim()),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return result;
  }

  Future<void> _handleInboxSelection({
    required String syncKey,
    required String name,
    required String? passwordHash,
  }) async {
    if ((passwordHash ?? '').isEmpty) {
      controller.selectInbox(syncKey, name);
      return;
    }

    final unlockedWithBiometric = await controller.canAccessLockedInbox(
      name: name,
      expectedPasswordHash: passwordHash,
      password: '',
    );
    if (unlockedWithBiometric) {
      controller.selectInbox(syncKey, name);
      return;
    }
    if (!mounted) {
      return;
    }

    final pass = await _showPasswordDialog(
      context,
      title: 'Unlock "$name"',
      confirmLabel: 'Unlock',
    );
    if (pass == null || pass.isEmpty) {
      controller.status.value = 'Unlock cancelled.';
      controller.clearSelectedInbox();
      return;
    }

    final unlocked = await controller.canAccessLockedInbox(
      name: name,
      expectedPasswordHash: passwordHash,
      password: pass,
    );
    if (!unlocked) {
      controller.status.value = 'Incorrect password for "$name".';
      controller.clearSelectedInbox();
      return;
    }
    controller.selectInbox(syncKey, name);
  }

  Future<void> _handleSetInboxPassword({
    required String syncKey,
    required String name,
  }) async {
    final currentHash = await controller.getInboxPasswordHash(syncKey);

    if ((currentHash ?? '').isNotEmpty) {
      final biometricOk = await controller.canAccessLockedInbox(
        name: name,
        expectedPasswordHash: currentHash,
        password: '',
      );

      if (!biometricOk) {
        if (!mounted) {
          return;
        }
        final currentPass = await _showPasswordDialog(
          context,
          title: 'Enter current password for "$name"',
          confirmLabel: 'Verify',
        );
        if (currentPass == null || currentPass.isEmpty) {
          controller.status.value = 'Password update cancelled.';
          return;
        }

        final currentPassOk = await controller.canAccessLockedInbox(
          name: name,
          expectedPasswordHash: currentHash,
          password: currentPass,
        );
        if (!currentPassOk) {
          controller.status.value = 'Current password is incorrect.';
          return;
        }
      }
    }

    if (!mounted) {
      return;
    }
    final newPass = await _showPasswordDialog(
      context,
      title: 'Set new password for "$name"',
      confirmLabel: 'Save',
    );
    if (newPass == null || newPass.isEmpty) {
      controller.status.value = 'Password update cancelled.';
      return;
    }

    await controller.setInboxPassword(syncKey: syncKey, password: newPass);
  }

  Future<void> _handleDeleteInbox({
    required String syncKey,
    required String name,
  }) async {
    final deletingDefaultSyncInbox = controller.isDefaultSyncInbox(syncKey);
    final passwordHash = await controller.getInboxPasswordHash(syncKey);
    if ((passwordHash ?? '').isNotEmpty) {
      final biometricOk = await controller.canAccessLockedInbox(
        name: name,
        expectedPasswordHash: passwordHash,
        password: '',
      );
      if (!biometricOk) {
        if (!mounted) {
          return;
        }
        final pass = await _showPasswordDialog(
          context,
          title: 'Confirm "$name" for delete',
          confirmLabel: 'Verify',
        );
        if (pass == null || pass.isEmpty) {
          controller.status.value = 'Delete cancelled.';
          return;
        }
        final passOk = await controller.canAccessLockedInbox(
          name: name,
          expectedPasswordHash: passwordHash,
          password: pass,
        );
        if (!passOk) {
          controller.status.value = 'Incorrect password for "$name".';
          return;
        }
      }
    }

    if (!mounted) {
      return;
    }
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Delete Inbox'),
              content: Text(
                deletingDefaultSyncInbox
                    ? 'Delete "$name" and all synced SMS/calls in it?\n\nThis is your default sync inbox. Sync will stop until you choose another default in Settings.'
                    : 'Delete "$name" and all synced SMS/calls in it? This cannot be undone.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _dangerColor,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirmed) {
      return;
    }

    await controller.deleteInbox(syncKey: syncKey, name: name);
  }

  String get _tabTitle {
    switch (_currentTab) {
      case 1:
        return 'Calls';
      case 2:
        return 'Settings';
      case 3:
        return 'Profile';
      default:
        return 'Chats';
    }
  }

  Widget _tabContent() {
    switch (_currentTab) {
      case 1:
        return _CallsPanel(controller: controller);
      case 2:
        return _SettingsPanel(controller: controller);
      case 3:
        return _ProfilePanel(controller: controller);
      default:
        return _MessagesPanel(controller: controller);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: colors.surface,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Row(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: colors.primary.withValues(alpha: 0.22),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const ChaBridgeLogo(size: 38),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cha Bridge · $_tabTitle',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          user?.email ?? user?.uid ?? '-',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Column(
                  children: [
                    if (_currentTab == 0 || _currentTab == 1) ...[
                      _InboxSelectorCard(
                        controller: controller,
                        onSelectInbox: _handleInboxSelection,
                        onSetPassword: _handleSetInboxPassword,
                        onDeleteInbox: _handleDeleteInbox,
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (_currentTab == 0 || _currentTab == 1) ...[
                      Obx(
                        () => Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Status: ${controller.status.value}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Expanded(child: _tabContent()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: colors.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: colors.shadow.withValues(alpha: 0.08),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              _IslandNavItem(
                icon: Icons.chat_bubble,
                label: 'Chats',
                isSelected: _currentTab == 0,
                onTap: () => setState(() => _currentTab = 0),
              ),
              _IslandNavItem(
                icon: Icons.call,
                label: 'Calls',
                isSelected: _currentTab == 1,
                onTap: () => setState(() => _currentTab = 1),
              ),
              _IslandNavItem(
                icon: Icons.settings,
                label: 'Settings',
                isSelected: _currentTab == 2,
                onTap: () => setState(() => _currentTab = 2),
              ),
              _IslandNavItem(
                icon: Icons.person,
                label: 'Profile',
                isSelected: _currentTab == 3,
                onTap: () => setState(() => _currentTab = 3),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: _currentTab <= 1
          ? FloatingActionButton(
              onPressed: () => _showCreateInboxDialog(context, controller),
              child: const Icon(Icons.add_comment),
            )
          : null,
    );
  }
}

class _InboxSelectorCard extends StatelessWidget {
  const _InboxSelectorCard({
    required this.controller,
    required this.onSelectInbox,
    required this.onSetPassword,
    required this.onDeleteInbox,
  });

  final SmsSyncController controller;
  final Future<void> Function({
    required String syncKey,
    required String name,
    required String? passwordHash,
  })
  onSelectInbox;
  final Future<void> Function({required String syncKey, required String name})
  onSetPassword;
  final Future<void> Function({required String syncKey, required String name})
  onDeleteInbox;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.forum_outlined, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: controller.inboxesStream(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const LinearProgressIndicator();
                }

                final docs =
                    [
                      ...snapshot.data!.docs.where(
                        (doc) => !controller.isInboxDeleted(doc.data()),
                      ),
                    ]..sort((a, b) {
                      final aMs =
                          (a.data()['createdAt'] as Timestamp?)
                              ?.millisecondsSinceEpoch ??
                          0;
                      final bMs =
                          (b.data()['createdAt'] as Timestamp?)
                              ?.millisecondsSinceEpoch ??
                          0;
                      return bMs.compareTo(aMs);
                    });

                if (docs.isEmpty) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (controller.selectedSyncKey.value.isNotEmpty) {
                      controller.clearSelectedInbox();
                    }
                  });
                  return const Text('No active inbox.');
                }

                final selectedKey = controller.selectedSyncKey.value;
                if (selectedKey.isNotEmpty &&
                    !docs.any(
                      (doc) =>
                          ((doc.data()['syncKey'] as String?) ?? doc.id) ==
                          selectedKey,
                    )) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (controller.selectedSyncKey.value == selectedKey) {
                      controller.clearSelectedInbox();
                    }
                  });
                }

                return Obx(() {
                  final selected = controller.selectedSyncKey.value;
                  return DropdownButtonFormField<String>(
                    key: ValueKey(selected),
                    initialValue: selected.isEmpty ? null : selected,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Current inbox',
                      hintText: 'Select inbox',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: docs.map((doc) {
                      final data = doc.data();
                      final name = (data['name'] as String?) ?? 'Inbox';
                      final key = (data['syncKey'] as String?) ?? doc.id;
                      final locked = controller.isInboxProtected(data);
                      final isDefault = controller.isDefaultSyncInbox(key);
                      return DropdownMenuItem<String>(
                        value: key,
                        child: Text(
                          locked
                              ? (isDefault
                                  ? '$name (Locked • Default Sync)'
                                  : '$name (Locked)')
                              : (isDefault ? '$name (Default Sync)' : name),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (value) async {
                      if (value == null) {
                        return;
                      }

                      final matched = docs.firstWhere(
                        (doc) =>
                            ((doc.data()['syncKey'] as String?) ?? doc.id) ==
                            value,
                      );
                      final name =
                          (matched.data()['name'] as String?) ?? 'Inbox';
                      final passwordHash =
                          matched.data()['passwordHash'] as String?;
                      await onSelectInbox(
                        syncKey: value,
                        name: name,
                        passwordHash: passwordHash,
                      );
                    },
                  );
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Obx(() {
            final selected = controller.selectedSyncKey.value;
            final selectedName = controller.selectedInboxName.value;
            return PopupMenuButton<String>(
              tooltip: 'Inbox actions',
              enabled: selected.isNotEmpty && !controller.isDeletingInbox.value,
              onSelected: (value) {
                if (value == 'lock') {
                  onSetPassword(syncKey: selected, name: selectedName);
                  return;
                }
                if (value == 'refresh') {
                  controller.pullFromFirebase();
                  return;
                }
                if (value == 'default') {
                  controller.setDefaultSyncInbox(
                    syncKey: selected,
                    name: selectedName,
                  );
                  return;
                }
                if (value == 'delete') {
                  onDeleteInbox(syncKey: selected, name: selectedName);
                }
              },
              itemBuilder: (context) {
                final isDefault = controller.isDefaultSyncInbox(selected);
                return [
                PopupMenuItem<String>(
                  value: 'refresh',
                  enabled: !controller.isPulling.value,
                  child: Row(
                    children: [
                      controller.isPulling.value
                          ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.refresh),
                      const SizedBox(width: 8),
                      const Text('Refresh from Firebase'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'lock',
                  child: Row(
                    children: [
                      Icon(Icons.lock_outline),
                      SizedBox(width: 8),
                      Text('Set password'),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'default',
                  child: Row(
                    children: [
                      Icon(isDefault ? Icons.check_circle : Icons.sync),
                      const SizedBox(width: 8),
                      Text(
                        isDefault
                            ? 'Default sync inbox'
                            : 'Set as default sync inbox',
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        color: _SmsSyncScreenState._dangerColor,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Delete inbox',
                        style: TextStyle(
                          color: _SmsSyncScreenState._dangerColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ];
              },
              child: controller.isDeletingInbox.value
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.more_vert),
                    ),
            );
          }),
        ],
      ),
    );
  }
}

class _MessagesPanel extends StatelessWidget {
  const _MessagesPanel({required this.controller});

  final SmsSyncController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Obx(
        () => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: controller.syncedMessagesStream(),
          builder: (context, snapshot) {
            if (controller.selectedSyncKey.value.trim().isEmpty) {
              return const Center(
                child: Text('Select an inbox to view synced chats.'),
              );
            }
            if (snapshot.hasError) {
              final errorText = '${snapshot.error}'.toLowerCase();
              if (errorText.contains('permission-denied') ||
                  errorText.contains('insufficient permissions')) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  controller.retryAfterPermissionDenied();
                });
                return const Center(child: Text('Connecting to inbox...'));
              }
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Firestore error: ${snapshot.error}'),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final docs = snapshot.data!.docs;
            if (docs.isEmpty) {
              return const Center(child: Text('No synced messages yet.'));
            }

            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: docs.length,
              separatorBuilder: (_, index) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final data = docs[index].data();
                final millis =
                    (data['smsDate'] as Timestamp?)?.millisecondsSinceEpoch ??
                    0;
                final date = DateTime.fromMillisecondsSinceEpoch(millis);

                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest.withValues(
                      alpha: 0.55,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        controller.decryptForDisplay(
                                  data['address'] as String?,
                                ) ==
                                ''
                            ? 'Unknown sender'
                            : controller.decryptForDisplay(
                                data['address'] as String?,
                              ),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        controller.decryptForDisplay(data['body'] as String?),
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _CallsPanel extends StatelessWidget {
  const _CallsPanel({required this.controller});

  final SmsSyncController controller;

  String _callTypeLabel(String value) {
    switch (value) {
      case 'incoming':
        return 'Incoming';
      case 'outgoing':
        return 'Outgoing';
      case 'missed':
        return 'Missed';
      case 'rejected':
        return 'Rejected';
      default:
        return 'Other';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Obx(
        () => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: controller.syncedCallsStream(),
          builder: (context, snapshot) {
            if (controller.selectedSyncKey.value.trim().isEmpty) {
              return const Center(
                child: Text('Select an inbox to view synced calls.'),
              );
            }
            if (snapshot.hasError) {
              final errorText = '${snapshot.error}'.toLowerCase();
              if (errorText.contains('permission-denied') ||
                  errorText.contains('insufficient permissions')) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  controller.retryAfterPermissionDenied();
                });
                return const Center(child: Text('Connecting to inbox...'));
              }
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Firestore error: ${snapshot.error}'),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final docs = snapshot.data!.docs;
            if (docs.isEmpty) {
              return const Center(child: Text('No synced calls yet.'));
            }

            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: docs.length,
              separatorBuilder: (_, index) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final data = docs[index].data();
                final millis =
                    (data['callDate'] as Timestamp?)?.millisecondsSinceEpoch ??
                    0;
                final date = DateTime.fromMillisecondsSinceEpoch(millis);
                final durationSec = (data['durationSec'] as int?) ?? 0;
                final callType = controller.decryptForDisplay(
                  data['callType'] as String?,
                );
                final isMissed = callType == 'missed';

                return ListTile(
                  tileColor: colors.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  leading: Icon(
                    isMissed ? Icons.call_missed : Icons.call,
                    color: isMissed ? Colors.red : colors.primary,
                  ),
                  title: Text(
                    controller.decryptForDisplay(data['name'] as String?) != ''
                        ? controller.decryptForDisplay(data['name'] as String?)
                        : controller.decryptForDisplay(
                                data['number'] as String?,
                              ) !=
                              ''
                        ? controller.decryptForDisplay(
                            data['number'] as String?,
                          )
                        : 'Unknown',
                  ),
                  subtitle: Text(
                    '${_callTypeLabel(callType)} • ${durationSec}s • ${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.controller});

  final SmsSyncController controller;

  @override
  Widget build(BuildContext context) {
    final themeController = Get.find<AppThemeController>();
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: controller.inboxesStream(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox.shrink();
            }

            final docs = [
              ...snapshot.data!.docs.where(
                (doc) => !controller.isInboxDeleted(doc.data()),
              ),
            ]..sort((a, b) {
              final aMs =
                  (a.data()['createdAt'] as Timestamp?)
                      ?.millisecondsSinceEpoch ??
                  0;
              final bMs =
                  (b.data()['createdAt'] as Timestamp?)
                      ?.millisecondsSinceEpoch ??
                  0;
              return bMs.compareTo(aMs);
            });

            if (docs.isEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (controller.defaultSyncInboxKey.value.isNotEmpty) {
                  controller.clearDefaultSyncInbox(silent: true);
                }
              });
              return const ListTile(
                title: Text('Default sync inbox'),
                subtitle: Text('No active inbox available'),
              );
            }

            return Obx(() {
              final selectedDefault = controller.defaultSyncInboxKey.value;
              final hasSelected = docs.any(
                (doc) =>
                    ((doc.data()['syncKey'] as String?) ?? doc.id) ==
                    selectedDefault,
              );
              if (!hasSelected) {
                final first = docs.first.data();
                final firstKey = (first['syncKey'] as String?) ?? docs.first.id;
                final firstName = (first['name'] as String?) ?? 'Inbox';
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (controller.defaultSyncInboxKey.value != firstKey) {
                    controller.setDefaultSyncInbox(
                      syncKey: firstKey,
                      name: firstName,
                      silent: true,
                    );
                  }
                });
              }

              return ListTile(
                title: const Text('Default sync inbox'),
                subtitle: DropdownButtonFormField<String>(
                  initialValue: hasSelected ? selectedDefault : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    hintText: 'Choose where sync data is saved',
                  ),
                  items: docs.map((doc) {
                    final data = doc.data();
                    final key = (data['syncKey'] as String?) ?? doc.id;
                    final name = (data['name'] as String?) ?? 'Inbox';
                    return DropdownMenuItem<String>(
                      value: key,
                      child: Text(name, overflow: TextOverflow.ellipsis),
                    );
                  }).toList(),
                  onChanged: (value) async {
                    if (value == null) {
                      return;
                    }
                    final matched = docs.firstWhere(
                      (doc) =>
                          ((doc.data()['syncKey'] as String?) ?? doc.id) ==
                          value,
                    );
                    final name = (matched.data()['name'] as String?) ?? 'Inbox';
                    await controller.setDefaultSyncInbox(
                      syncKey: value,
                      name: name,
                    );
                  },
                ),
              );
            });
          },
        ),
        const Divider(height: 1),
        Obx(
          () => SwitchListTile(
            title: const Text('Auto-sync on open/resume'),
            subtitle: const Text(
              'Sync call logs when app opens/resumes. Incoming SMS syncs on receive.',
            ),
            value: controller.autoSyncOnResume.value,
            onChanged: controller.setAutoSyncOnResume,
          ),
        ),
        const Divider(height: 1),
        Obx(
          () => SwitchListTile(
            title: const Text('Periodic call sync while open'),
            subtitle: Text(
              'Every ${controller.periodicSyncIntervalMinutes.value} minutes',
            ),
            value: controller.periodicSyncEnabled.value,
            onChanged: controller.setPeriodicSyncEnabled,
          ),
        ),
        Obx(
          () => ListTile(
            title: const Text('Foreground call sync interval'),
            subtitle: Slider(
              value: controller.periodicSyncIntervalMinutes.value.toDouble(),
              min: 1,
              max: 60,
              divisions: 59,
              label: '${controller.periodicSyncIntervalMinutes.value} min',
              onChanged:
                  (value) => controller.setPeriodicSyncIntervalMinutes(
                    value.round(),
                  ),
            ),
            trailing: Text('${controller.periodicSyncIntervalMinutes.value}m'),
          ),
        ),
        const Divider(height: 1),
        Obx(
          () => SwitchListTile(
            title: const Text('Background call sync (Android)'),
            subtitle: Text(
              controller.backgroundSyncIntervalMinutes.value < 15
                  ? 'Relay mode every ${controller.backgroundSyncIntervalMinutes.value} min. Incoming SMS syncs on receive.'
                  : 'WorkManager every ${controller.backgroundSyncIntervalMinutes.value} min. Incoming SMS syncs on receive.',
            ),
            value: controller.backgroundSyncEnabled.value,
            onChanged: controller.setBackgroundSyncEnabled,
          ),
        ),
        Obx(
          () => ListTile(
            title: const Text('Background call sync interval'),
            subtitle: Slider(
              value: controller.backgroundSyncIntervalMinutes.value.toDouble(),
              min: 1,
              max: 180,
              divisions: 179,
              label: '${controller.backgroundSyncIntervalMinutes.value} min',
              onChanged:
                  (value) => controller.setBackgroundSyncIntervalMinutes(
                    value.round(),
                  ),
            ),
            trailing: Text('${controller.backgroundSyncIntervalMinutes.value}m'),
          ),
        ),
        const Divider(height: 1),
        Obx(
          () => ListTile(
            title: const Text('Battery optimization'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  controller.batteryOptimizationIgnored.value
                      ? 'Disabled for Cha Bridge'
                      : 'Enabled (can stop background sync)',
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: controller.refreshBatteryOptimizationStatus,
                      child: const Text('Check'),
                    ),
                    ElevatedButton(
                      onPressed:
                          controller.requestBatteryOptimizationExemption,
                      child: const Text('Allow'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        ListTile(
          title: const Text('Open battery settings'),
          subtitle: const Text('Use if your phone still kills background sync'),
          onTap: controller.openBatteryOptimizationSettings,
          trailing: const Icon(Icons.open_in_new),
        ),
        const Divider(height: 1),
        Obx(
          () => SwitchListTile(
            title: const Text('Dark mode'),
            value: themeController.isDarkMode,
            onChanged: themeController.setDarkMode,
          ),
        ),
        const Divider(height: 1),
        Obx(
          () => SwitchListTile(
            title: const Text('Fingerprint inbox unlock'),
            subtitle: const Text('Use biometrics for locked inboxes'),
            value: controller.biometricUnlockEnabled.value,
            onChanged: controller.setBiometricUnlockEnabled,
          ),
        ),
        const SizedBox(height: 14),
        Obx(
          () => ElevatedButton.icon(
            onPressed: controller.isSyncing.value ? null : controller.syncSms,
            icon: const Icon(Icons.sms),
            label: const Text('Sync SMS'),
          ),
        ),
        const SizedBox(height: 8),
        Obx(
          () => ElevatedButton.icon(
            onPressed: controller.isSyncing.value ? null : controller.syncCalls,
            icon: const Icon(Icons.call),
            label: const Text('Sync Calls'),
          ),
        ),
        const SizedBox(height: 8),
        Obx(
          () => OutlinedButton.icon(
            onPressed: controller.isSyncing.value ? null : controller.syncAll,
            icon: const Icon(Icons.sync),
            label: const Text('Sync SMS + Calls'),
          ),
        ),
      ],
    );
  }
}

class _ProfilePanel extends StatelessWidget {
  const _ProfilePanel({required this.controller});

  final SmsSyncController controller;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final themeController = Get.find<AppThemeController>();
    final colors = Theme.of(context).colorScheme;

    return ListView(
      children: [
        ListTile(
          tileColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: const CircleAvatar(child: Icon(Icons.person)),
          title: Text(user?.email ?? 'No email'),
          subtitle: Text('UID: ${user?.uid ?? '-'}'),
        ),
        const SizedBox(height: 10),
        Obx(
          () => ListTile(
            tileColor: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            leading: const Icon(Icons.folder_shared),
            title: const Text('Currently Open Inbox'),
            subtitle: Text(
              controller.selectedSyncKey.value.isEmpty
                  ? '-'
                  : controller.selectedSyncKey.value,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Obx(
          () => ListTile(
            tileColor: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            leading: const Icon(Icons.sync),
            title: const Text('Default Sync Inbox'),
            subtitle: Text(
              controller.defaultSyncInboxName.value.isNotEmpty
                  ? '${controller.defaultSyncInboxName.value} (${controller.defaultSyncInboxKey.value})'
                  : '-',
            ),
          ),
        ),
        const SizedBox(height: 10),
        Obx(
          () => ListTile(
            tileColor: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            leading: Icon(
              themeController.isDarkMode ? Icons.dark_mode : Icons.light_mode,
            ),
            title: const Text('Appearance'),
            subtitle: Text(
              themeController.isDarkMode ? 'Dark mode enabled' : 'Light mode',
            ),
          ),
        ),
        const SizedBox(height: 10),
        ListTile(
          tileColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: const Icon(Icons.logout),
          title: const Text('Sign Out'),
          onTap: () async {
            await GoogleSignIn.instance.signOut();
            await FirebaseAuth.instance.signOut();
          },
        ),
      ],
    );
  }
}

class _IslandNavItem extends StatelessWidget {
  const _IslandNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? colors.primaryContainer.withValues(alpha: 0.8)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
