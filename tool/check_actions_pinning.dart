import 'dart:io';

const workflowsPath = '.github/workflows';

void main() {
  final failures = <String>[];
  final workflowFiles = Directory(workflowsPath)
      .listSync()
      .whereType<File>()
      .where(
        (file) => file.path.endsWith('.yaml') || file.path.endsWith('.yml'),
      )
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final workflow in workflowFiles) {
    failures.addAll(
      findUnpinnedActions(
        workflow.readAsStringSync(),
        sourcePath: workflow.path,
      ),
    );
  }

  if (failures.isNotEmpty) {
    stderr.writeln('GitHub Actions pinning guard failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'GitHub Actions pinning guard passed for ${workflowFiles.length} workflows.',
  );
}

List<String> findUnpinnedActions(
  String workflow, {
  required String sourcePath,
}) {
  final failures = <String>[];
  final usesPattern = RegExp(r'''^\s*(?:-\s*)?uses:\s*["']?([^\s"'#]+)''');
  final fullCommitSha = RegExp(r'^[0-9a-fA-F]{40}$');
  final lines = workflow.split('\n');

  for (var index = 0; index < lines.length; index++) {
    final action = usesPattern.firstMatch(lines[index])?.group(1);
    if (action == null ||
        action.startsWith('./') ||
        action.startsWith('docker://')) {
      continue;
    }

    final separator = action.lastIndexOf('@');
    final reference = separator < 0 ? '' : action.substring(separator + 1);
    if (!fullCommitSha.hasMatch(reference)) {
      failures.add(
        '$sourcePath:${index + 1} uses `$action`; pin remote actions to a '
        'full 40-character commit SHA.',
      );
    }
  }

  return failures;
}
