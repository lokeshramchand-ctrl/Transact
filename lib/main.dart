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
  final Dio _dio = Dio();

  // Connects to local FastAPI instance
  final String _baseUrl = "http://10.0.2.2:8080";
  final String _apiKey = "velar_test_key_123";

  bool _isProcessing = false;
  String _statusText =
      "Upload a Bank/UPI PDF statement to extract and categorize transactions.";
  final List<Map<String, dynamic>> _transactions = [];

  Future<void> _pickAndProcessPDF() async {
    try {
      // 1. Open the native file picker
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
          _statusText = "Extracting text locally from PDF...";
          _transactions.clear();
        });

        // 2. Read and Extract PDF Text securely on the device
        final bytes = await result.readAsBytes();
        final PdfDocument document = PdfDocument(inputBytes: bytes);
        final String text = PdfTextExtractor(document).extractText();
        document.dispose();

        // 3. Ultimate GPay Smart Parser
        List<String> potentialTransactions = [];

        // --- STRATEGY 1: CSV / Columnar Format ---
        // Syncfusion sometimes outputs tables as "Col1","Col2","Col3"
        final csvRowRegex = RegExp(
          r'"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"',
        );
        final csvMatches = csvRowRegex.allMatches(text);

        if (csvMatches.isNotEmpty) {
          final merchantRegex = RegExp(r'(Paid to|Received from)\s+([^\r\n]+)');
          final amountRegex = RegExp(
            r'(?:₹\s*)?([0-9]+(?:,[0-9]+)*(?:\.[0-9]+)?)',
          );

          for (var row in csvMatches) {
            String col2 = row.group(2) ?? '';
            String col3 = row.group(3) ?? '';

            var merchants = merchantRegex.allMatches(col2).toList();
            var amounts = amountRegex.allMatches(col3).toList();

            // Pair the arrays together
            int count = merchants.length < amounts.length
                ? merchants.length
                : amounts.length;
            for (int i = 0; i < count; i++) {
              String type = merchants[i].group(1)!.trim();
              String name = merchants[i].group(2)!.trim();
              String amt = amounts[i].group(1)!.replaceAll(',', '');
              String rawTx = "$type $name ₹$amt";
              if (!potentialTransactions.contains(rawTx)) {
                potentialTransactions.add(rawTx);
              }
            }
          }
        }

        // --- STRATEGY 2: Flexible Line-by-Line with Stateful Lookahead ---
        // If Strategy 1 missed things (or wasn't CSV formatted), fallback to this robust crawler
        if (potentialTransactions.isEmpty) {
          List<String> lines = text.split(RegExp(r'\r?\n'));
          Set<int> consumedAmountLines =
              {}; // Tracks amounts we've already paired to prevent double-counting

          for (int i = 0; i < lines.length; i++) {
            String line = lines[i];

            // Match "Paid to" or "Received from" and stop before UPI or ₹
            final merchantMatch = RegExp(
              r'(Paid to|Received from)\s+(.*?)(?=₹|UPI|Paid|$)',
            ).firstMatch(line);

            if (merchantMatch != null) {
              String type = merchantMatch.group(1)!.trim();
              String merchant = merchantMatch.group(2)!.trim();
              // Fixed the regex syntax here by using a standard string instead of a raw string
              merchant = merchant
                  .replaceAll(RegExp('["\',]'), '')
                  .trim(); // Sanitize

              String amount = "";

              // A. Check if amount is sitting directly on the same line
              final sameLineAmountMatch = RegExp(
                r'₹\s*([0-9]+(?:,[0-9]+)*(?:\.[0-9]+)?)',
              ).firstMatch(line);
              if (sameLineAmountMatch != null) {
                amount = sameLineAmountMatch.group(1)!;
              } else {
                // B. Look ahead up to 20 lines (to jump over grouped columns)
                for (int j = 1; j <= 20; j++) {
                  int targetIdx = i + j;
                  if (targetIdx < lines.length &&
                      !consumedAmountLines.contains(targetIdx)) {
                    String lookAhead = lines[targetIdx].trim();

                    // Check for standard format with ₹
                    final aheadAmountMatch = RegExp(
                      r'₹\s*([0-9]+(?:,[0-9]+)*(?:\.[0-9]+)?)',
                    ).firstMatch(lookAhead);
                    if (aheadAmountMatch != null) {
                      amount = aheadAmountMatch.group(1)!;
                      consumedAmountLines.add(targetIdx);
                      break;
                    }

                    // Fallback for amounts missing the ₹ symbol (e.g. "246.43")
                    if (RegExp(
                      r'^([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?)$',
                    ).hasMatch(lookAhead)) {
                      // Ensure it's not a bank ID suffix like "5488" or a date chunk
                      if (lookAhead != "5488" &&
                          lookAhead.length < 8 &&
                          !lookAhead.startsWith('202')) {
                        amount = lookAhead;
                        consumedAmountLines.add(targetIdx);
                        break;
                      }
                    }
                  }
                }
              }

              if (amount.isNotEmpty) {
                String rawTx = "$type $merchant ₹${amount.replaceAll(',', '')}"
                    .trim();
                if (!potentialTransactions.contains(rawTx)) {
                  potentialTransactions.add(rawTx);
                }
              }
            }
          }
        }

        // We limit to 20 for testing so we don't trigger your SlowAPI rate limits!
        final testBatch = potentialTransactions.take(20).toList();

        if (testBatch.isEmpty) {
          setState(() {
            _statusText =
                "No recognizable GPay transactions found in this PDF.\nEnsure it's a standard Google Pay statement.";
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
