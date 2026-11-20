import 'package:flutter/cupertino.dart';

import '../config/api_config.dart';

class ApiTokenPage extends StatefulWidget {
  const ApiTokenPage({required this.onSaved, super.key});

  final VoidCallback onSaved;

  @override
  State<ApiTokenPage> createState() => _ApiTokenPageState();
}

class _ApiTokenPageState extends State<ApiTokenPage> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final token = _controller.text.trim();
    if (token.isEmpty) {
      setState(() {});
      return;
    }
    setState(() => _saving = true);
    await saveApiToken(token);
    if (!mounted) return;
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('连接 TillRoads')),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            const SizedBox(height: 48),
            const Text(
              '输入 API Token',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'Token 仅保存在本机，用于访问 Railway API。也可以通过 API_TOKEN dart-define 预置。',
            ),
            const SizedBox(height: 28),
            CupertinoTextField(
              controller: _controller,
              obscureText: true,
              placeholder: 'API Token',
              padding: const EdgeInsets.all(16),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const CupertinoActivityIndicator()
                  : const Text('保存并继续'),
            ),
          ],
        ),
      ),
    );
  }
}
