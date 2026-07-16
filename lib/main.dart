import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  runApp(const VelarApp());
}

class VelarApp extends StatelessWidget {
  const VelarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Velar Frontend',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E293B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const IngestionScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class IngestionScreen extends StatefulWidget {
  const IngestionScreen({super.key});

  @override
  State<IngestionScreen> createState() => _IngestionScreenState();
}

class _IngestionScreenState extends State<IngestionScreen> {
  // Added 5-second timeouts so the app never hangs indefinitely!
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  // Connects to local FastAPI instance
  final String _baseUrl = "http://10.0.2.2:8080";
  final String _apiKey = "velar_test_key_123";

  bool _isProcessing = false;
  double _progressValue = 0.0;
  String _statusText =
      "Upload a Bank/UPI PDF statement to extract and categorize transactions.";
  final List<Map<String, dynamic>> _transactions = [];

  // Stores step-by-step parsing details for debugging
  final List<String> _debugLogs = [];

  void _showDebugLogs() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          "Extraction Logs",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _debugLogs.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(bottom: 6.0),
              child: Text(
                _debugLogs[index],
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: _debugLogs[index].startsWith('✅')
                      ? Colors.green.shade700
                      : _debugLogs[index].startsWith('⚠️')
                      ? Colors.orange.shade700
                      : _debugLogs[index].startsWith('❌')
                      ? Colors.red.shade700
                      : Colors.black87,
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndProcessPDF() async {
    try {
      const XTypeGroup pdfTypeGroup = XTypeGroup(
        label: 'PDFs',
        extensions: <String>['pdf'],
      );

      final XFile? result = await openFile(
        acceptedTypeGroups: <XTypeGroup>[pdfTypeGroup],
      );

      if (result != null) {
        setState(() {
          _isProcessing = true;
          _progressValue = 0.0;
          _statusText = "Extracting text locally from PDF...";
          _transactions.clear();
          _debugLogs.clear();
        });

        _debugLogs.add("--- STARTING VISUAL COORDINATE EXTRACTION ---");

        final bytes = await result.readAsBytes();
        final PdfDocument document = PdfDocument(inputBytes: bytes);
        final PdfTextExtractor extractor = PdfTextExtractor(document);

        List<String> potentialTransactions = [];

        // Process page by page
        for (int pageIndex = 0; pageIndex < document.pages.count; pageIndex++) {
          // 1. Extract raw lines WITH their X and Y bounding coordinates
          List<TextLine> textLines = extractor.extractTextLines(
            startPageIndex: pageIndex,
            endPageIndex: pageIndex,
          );
          List<List<TextLine>> rows = [];

          // 2. Group chunks by Y-Coordinate (tolerance of 5.0 points for slight vertical misalignments)
          for (var tl in textLines) {
            bool added = false;
            for (var row in rows) {
              if ((row.first.bounds.top - tl.bounds.top).abs() < 5.0) {
                row.add(tl);
                added = true;
                break;
              }
            }
            if (!added) {
              rows.add([tl]);
            }
          }

          // 3. Sort rows top-to-bottom
          rows.sort((a, b) => a.first.bounds.top.compareTo(b.first.bounds.top));

          int pageMatches = 0;

          // 4. Sort each chunk left-to-right to reconstruct the visual sentence
          for (var row in rows) {
            row.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));

            // Stitch the line together
            String fullLine = row.map((e) => e.text.trim()).join(' ').trim();

            if (fullLine.isEmpty || fullLine.startsWith('Page ')) continue;

            // 5. Strict Regex: Match type, merchant, and the amount strictly at the END of the visual line
            final match = RegExp(
              r'(Paid to|Received from|Sent to)\s+(.+?)\s+(?:₹|Rs\.?)?\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.\d{1,2})?)$',
              caseSensitive: false,
            ).firstMatch(fullLine);

            if (match != null) {
              String type = match.group(1)!.trim();
              String merchant = match.group(2)!.trim();
              String amount = match
                  .group(3)!
                  .replaceAll(',', ''); // Strip commas for backend

              String rawTx = "$type $merchant ₹$amount";
              if (!potentialTransactions.contains(rawTx)) {
                potentialTransactions.add(rawTx);
                pageMatches++;
                _debugLogs.add("✅ Extracted: $rawTx");
              }
            } else if (fullLine.toLowerCase().contains("paid to") ||
                fullLine.toLowerCase().contains("received from")) {
              // Log near-misses (e.g. lines that have 'Paid to' but the amount got pushed to the next line)
              _debugLogs.add("⚠️ Near Miss: $fullLine");
            }
          }

          _debugLogs.add(
            "Page ${pageIndex + 1}: Reconstructed ${rows.length} rows, found $pageMatches transactions.",
          );
        }

        document.dispose();

        _debugLogs.add(
          "\n--- TOTAL UNIQUE TRANSACTIONS FOUND: ${potentialTransactions.length} ---",
        );

        // We process EVERYTHING now! No more limit.
        final testBatch = potentialTransactions;

        if (testBatch.isEmpty) {
          setState(() {
            _statusText =
                "No recognizable GPay transactions found in this PDF.\nCheck the 'Bug' icon to see extraction logs.";
            _isProcessing = false;
          });
          return;
        }

        // Stream each transaction to the Velar Intelligence Engine
        for (int i = 0; i < testBatch.length; i++) {
          final txText = testBatch[i];

          // Update the UI Progress Bar
          setState(() {
            _progressValue = (i + 1) / testBatch.length;
            _statusText =
                "Categorizing ${i + 1}/${testBatch.length}...\nProcessing: $txText";
          });

          try {
            final response = await _dio.post(
              "$_baseUrl/v1/categorize",
              data: {"text": txText},
              options: Options(
                headers: {
                  "X-Velar-API-Key": _apiKey,
                  "Content-Type": "application/json",
                },
              ),
            );

            if (response.statusCode == 200) {
              setState(() {
                _transactions.add({
                  "raw": txText,
                  "merchant": response.data["merchant"],
                  "category": response.data["category"],
                  "confidence": response.data["confidence"],
                });
              });
            }
          } on DioException catch (e) {
            if (e.response?.statusCode == 429) {
              _debugLogs.add(
                "⚠️ Rate Limit Hit (429) for '$txText'. Backend blocked request.",
              );
            } else {
              _debugLogs.add("❌ Network/API Error for '$txText': ${e.message}");
            }
          } catch (e) {
            _debugLogs.add("❌ Unknown Error for '$txText': $e");
          }

          // 600ms delay perfectly aligns with 100 requests per minute!
          // This prevents SlowAPI from blocking the later transactions.
          await Future.delayed(const Duration(milliseconds: 600));
        }

        setState(() {
          _statusText =
              "✅ Successfully processed ${testBatch.length} transactions.";
        });
      }
    } catch (e) {
      setState(() {
        _statusText = "❌ Error processing PDF: $e";
      });
      _debugLogs.add("EXCEPTION CAUGHT: $e");
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Velar: Edge Ingestion'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // Top Control Panel
          Container(
            padding: const EdgeInsets.all(24.0),
            color: Colors.grey.shade50,
            child: Column(
              children: [
                Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.blueGrey.shade700,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_isProcessing) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: _progressValue > 0 ? _progressValue : null,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: FilledButton.icon(
                          onPressed: _isProcessing ? null : _pickAndProcessPDF,
                          icon: _isProcessing
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.upload_file_rounded),
                          label: Text(
                            _isProcessing
                                ? 'Processing PDF...'
                                : 'Upload Google Pay Statement',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Debug Logs Button
                    SizedBox(
                      height: 50,
                      child: IconButton.filledTonal(
                        onPressed: _debugLogs.isEmpty ? null : _showDebugLogs,
                        icon: const Icon(Icons.bug_report_rounded),
                        tooltip: 'View Extraction Logs',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Transaction Results List
          Expanded(
            child: _transactions.isEmpty && !_isProcessing
                ? Center(
                    child: Icon(
                      Icons.receipt_long_rounded,
                      size: 80,
                      color: Colors.grey.shade300,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _transactions.length,
                    itemBuilder: (context, index) {
                      // Reverse the list so newest transactions appear at the top
                      final tx =
                          _transactions[_transactions.length - 1 - index];
                      final isHighConfidence = tx['confidence'] >= 0.8;

                      return Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          side: BorderSide(color: Colors.grey.shade200),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            child: Icon(
                              Icons.storefront,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          title: Text(
                            tx['merchant'],
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            tx['raw'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                tx['category'],
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: tx['category'] == 'Unknown'
                                      ? Colors.red
                                      : Colors.green.shade700,
                                ),
                              ),
                              Text(
                                "${(tx['confidence'] * 100).toStringAsFixed(1)}%",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isHighConfidence
                                      ? Colors.grey.shade600
                                      : Colors.orange,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
