import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/src/utf16.dart';
import 'package:flutter/services.dart';
import 'package:koala/koala.dart';
import 'package:seldat/DatabaseManager.dart';
import 'package:sqflite/sqflite.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:win32/win32.dart';
import 'package:xml/xml.dart';
import 'package:xml/xpath.dart';

class LogFetcher {
  // Properties
  List<File> eventLogFileList = List.empty(growable: true);
  Function addCount = () {};
  Function addAnomalyCount = () {};
  bool isFetched = false;
  bool sigmaFinish = false;
  bool aiFinish = false;
  Function onAnalysisDone = () {};
  int anomalyCount = 0;
  final DatabaseManager db;

  // Constructor
  LogFetcher(this.db) {
    // Constructor code...
    if (!Directory(".\\Artifacts").existsSync()) {
      Directory(".\\Artifacts").create();
    }
    if (!Directory(".\\Artifacts\\EventLogs").existsSync()) {
      Directory(".\\Artifacts\\EventLogs").create();
    }
    if (!Directory(".\\Artifacts\\EvtxCsv").existsSync()) {
      Directory(".\\Artifacts\\EvtxCsv").create();
    }
  }

  void setAnomalyCount(Function addAnomalyCount) {
    this.addAnomalyCount = addAnomalyCount;
  }

  bool isAnalisisDone() {
    return sigmaFinish && aiFinish;
  }

  Future<bool> loadDB() async {
    List<Map<String, Object?>> evtxFileList = await db.getEvtxFileList();
    if (evtxFileList.isNotEmpty) {
      for (var file in evtxFileList) {
        eventLogFileList.add(File(file['filename'].toString()));
        addCount(int.parse(file['logCount'].toString()));
      }
      await db.getEvtxAnomalyCount().then((value) {
        anomalyCount = value;
        aiFinish = true;
        sigmaFinish = true;
        return true;
      });
      isFetched = true;
    }
    return false;
  }

  void setAddCount(Function addCount) {
    this.addCount = addCount;
  }

  bool getIsFetched() {
    return isFetched;
  }

  // Methods
  Future<void> scanFiles(Directory dir) async {
    await scan(dir);
    for (var file in eventLogFileList) {
      await parseEventLog(file, db);
    }
    await Future.wait([runAIModelPredict(), judgeSigmaRule()]).then((value) {
      isFetched = true;
    });
  }

  Future scan(Directory dir) async {
    Directory("Artifacts\\EventLogs").listSync().forEach((entity) {
      if (entity is File && entity.path.endsWith('.evtx')) {
        entity.delete();
      }
    });
    try {
      var dirList = dir.list();
      await for (final FileSystemEntity entity in dirList) {
        if (entity is File) {
          if (entity.path.endsWith(".evtx")) {
            // eventLogFileList.add(entity);
            if (entity.path.contains(
                "Microsoft-Windows-WER-PayloadHealth%4Operational.evtx")) {
              continue;
            }
            try {
              entity.copy(
                  "Artifacts\\EventLogs\\${entity.path.split('\\').last}");
              eventLogFileList.add(File(
                  "Artifacts\\EventLogs\\${entity.path.split('\\').last}"));
            } on PathExistsException catch (_, e) {}
          }
        } else if (entity is Directory) {
          scan(Directory(entity.path));
        }
      }
    } on PathAccessException {
      return;
    }
  }

  Future parseEventLog(File file, DatabaseManager db) async {
    await runevtxdump(file.path).then((value) async {
      List<eventLog> eventLogs = [];
      List<String> eventList = value.split(RegExp(r"Record [0-9]*"));
      for (String event in eventList) {
        XmlDocument record;
        try {
          record = XmlDocument.parse(event);
        } catch (e) {
          continue;
        }
        if (record.findAllElements("EventID").isEmpty) {
          continue;
        }
        String eventId = record.xpath("/Event/System/EventID").first.innerText;
        String? timeCreated = record
            .xpath("/Event/System/TimeCreated")
            .first
            .getAttribute("SystemTime");
        if (timeCreated == null) {
          continue;
        }
        int eventRecordId = int.parse(
            record.xpath("/Event/System/EventRecordID").first.innerText);

        eventLog log = eventLog(
            event_id: int.parse(eventId),
            filename: file.path,
            event_record_id: eventRecordId,
            full_log: event,
            sigmaLevel: 0,
            sigmaName: "",
            isMalicious: false,
            timestamp: DateTime.parse(timeCreated));
        eventLogs.add(log);
        //write to sqlite database
        addCount(1);
      }
      await db.insertEventLogs(eventLogs);
      await db.insertEvtxFiles(evtxFiles(
          filename: file.path, logCount: eventList.length, isFetched: true));
    });
  }

  Future<void> runAIModelPredict() async {
    Directory(".\\Artifacts\\EvtxCsv").listSync().forEach((entity) {
      if (entity is File && entity.path.endsWith('.csv')) {
        entity.delete();
      }
    });
    print("Running AI Model");
    await Process.run("./tools/runModel.exe", [],
            workingDirectory: "${Directory.current.path}/tools")
        .then((ProcessResult process) {
      bool isResult = false;
      process.stdout.toString().split("\n").forEach((element) {
        if (isResult) {
          if (element.length < 19) return;
          String timeGroup = element.substring(0, 11);
          bool isMalicious = element.contains("True");
          if (int.tryParse(timeGroup) == null) {
            print("Error: $element");
            return;
          }

          if (isMalicious) {
            db.updateMaliciousEvtx(int.parse(timeGroup) * 1000).then((value) {
              print("Anomaly Updated: $value");
              addAnomalyCount(value);
            });
          }
        }
        if (element.contains("[*] Printing results")) {
          isResult = true;
        }
      });
    }).then((value) {
      aiFinish = true;
      print("AI Model Finished");
      db.clearCache();
      Future.delayed(const Duration(seconds: 5), () {
        onAnalysisDone();
      });
    });
    // eventLog(event_id: 0, filename: "", full_log: "", isAnalyzed: false, riskScore: 0.0, timestamp: DateTime.now());
  }

  List<File> getEventLogFileList() {
    return eventLogFileList;
  }

  Future<String> runevtxdump(String path) async {
    var process =
        await Process.run('./tools/evtxdump.exe', [path], stdoutEncoding: utf8);

    return process.stdout;
  }

  Future<void> judgeSigmaRule() async {
    print("Running Sigma Detection");
    await Process.run(
            "./tools/chainsaw/chainsaw.exe",
            [
              "hunt",
              "../Artifacts/EventLogs/",
              "-s",
              "../rules",
              "--mapping",
              "chainsaw/mappings/sigma-event-logs-all.yml",
              "--json"
            ],
            workingDirectory: "${Directory.current.path}/tools",
            stdoutEncoding: Encoding.getByName("utf-8"))
        .then((ProcessResult process) async {
      bool isResult = false;
      if (process.exitCode != 0) {
        print("Error: ${process.stderr.toString()}");
        return;
      }
      final datas = jsonDecode(process.stdout.toString());
      for (var data in datas) {
        int eventRecordId = int.parse(data["document"]["data"]["Event"]
                ["System"]["EventRecordID"]
            .toString());
        String filename = data["document"]["path"]
            .toString()
            .substring(3)
            .replaceAll("/", "\\");
        String level = data["level"].toString();
        String name = data["name"].toString();
        db.updateSigmaRule(eventRecordId, filename, name, level);
        addAnomalyCount(1);
      }
      sigmaFinish = true;
      print("Sigma Finished");
      db.clearCache();
      onAnalysisDone();
    });
    return Future.value();
  }
}
