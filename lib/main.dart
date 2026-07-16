import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
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
  final Dio _dio = Dio();

  // Connects to local FastAPI instance
  final String _baseUrl = "http://192.168.1.44:8000";
  final String _apiKey = "velar_test_key_123";

  bool _isProcessing = false;
  String _statusText =
      "Upload a Bank/UPI PDF statement to extract and categorize transactions.";
  final List<Map<String, dynamic>> _transactions = [];

  Future<void> _pickAndProcessPDF() async {
    try {
      // 1. Open the native file picker
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result != null && result.files.single.path != null) {
        setState(() {
          _isProcessing = true;
          _statusText = "Extracting text locally from PDF...";
          _transactions.clear();
        });

        // 2. Read and Extract PDF Text securely on the device
        File file = File(result.files.single.path!);
        final bytes = await file.readAsBytes();
        final PdfDocument document = PdfDocument(inputBytes: bytes);
        final String text = PdfTextExtractor(document).extractText();
        document.dispose();

        // 3. Filter for likely transaction lines (Simple Heuristic Regex)
        List<String> lines = text.split('\n');
        List<String> potentialTransactions = [];
        final txRegex = RegExp(
          r'(UPI|Paid to|Sent to|IMPS|NEFT)',
          caseSensitive: false,
        );

        for (String line in lines) {
          if (line.trim().length > 10 && txRegex.hasMatch(line)) {
            potentialTransactions.add(line.trim());
          }
        }

        // We limit to 10 for testing so we don't trigger your SlowAPI rate limits!
        final testBatch = potentialTransactions.take(10).toList();

        if (testBatch.isEmpty) {
          setState(() {
            _statusText =
                "No recognizable UPI/Bank transactions found in this PDF.";
            _isProcessing = false;
          });
          return;
        }

        // 4. Stream each transaction to the Velar Intelligence Engine
        for (int i = 0; i < testBatch.length; i++) {
          final txText = testBatch[i];
          setState(() {
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
          } catch (e) {
            debugPrint("API Error for '$txText': $e");
          }

          // Small 300ms delay to prevent hammering the FastAPI server
          await Future.delayed(const Duration(milliseconds: 300));
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
                const SizedBox(height: 24),
                SizedBox(
                  height: 50,
                  width: double.infinity,
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
              ],
            ),
          ),
          const Divider(height: 1),

          // Transaction Results List
          Expanded(
            child: _transactions.isEmpty
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
                      final tx = _transactions[index];
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
