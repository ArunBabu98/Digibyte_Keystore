import 'dart:async';
import 'dart:typed_data';

import 'package:base58check/base58.dart';
import 'package:base58check/base58check.dart';
import 'package:bitcoin_flutter/bitcoin_flutter.dart';
import 'package:crypto/crypto.dart';
import 'package:digibyte_keystore/src/models/utxoModel.dart';
import 'package:digibyte_keystore/src/utils/api.dart';
import 'package:digibyte_keystore/src/utils/network.dart';
import 'package:digibyte_keystore/src/utils/utils.dart';
import 'package:hex/hex.dart';
import 'package:bitcoin_flutter/src/utils/script.dart' as sc;
import 'package:bitcoin_flutter/src/utils/constants/op.dart';

import 'models/encodedKeyModel.dart';

class DigiByteKeystore {
  late HDWallet mainWallet;
  late int coin;
  late Debug debug;
  late String digiassetNode;

  /// Initializes the keystore from a seed
  DigiByteKeystore.fromSeed(String digiassetcore, String seed, int coinValue,
      {bool log = false}) {
    mainWallet = HDWallet.fromSeed(convertHex(seed), network: digibyte);
    coin = coinValue;
    debug = Debug(flag: log);
    digiassetNode = digiassetcore;
  }

  /// Generates the least significant bytes for the given key index
  List<int> _generatelsbs(int aVal) {
    List<int> lsbs = [];
    for (int b = 0; b <= 255; b++) {
      HDWallet derived = mainWallet.derivePath("1000'/$coin'/$aVal'/$b");
      debug.log("Address $b -> ${derived.address}");
      int lsd = int.parse(leastSignificantDigit(derived.privKey!));
      lsbs.add(lsd);
    }
    return lsbs;
  }

  /// Extracts and XORs the key with the least significant bytes
  List<String> _getOPData(String key, List<int> lsbs) {
    Base58CheckCodec base58codec = Base58CheckCodec.bitcoin();
    try {
      Base58CheckPayload payload = base58codec.decode(key);
      Uint8List decoded = Uint8List.fromList(payload.payload);

      String pkey;
      if ((decoded.length == 33 && decoded[32] == 0x01) ||
          decoded.length == 38 && decoded[37] == 0x01) {
        pkey = HEX.encode(decoded.sublist(0, 32));
      } else {
        pkey = HEX.encode(payload.payload);
      }
      String xoredKey = xorWithLsb(pkey, lsbs);
      return [pkey, xoredKey];
    } catch (err) {
      debug.log("Error -> $err");
      String xoredKey = xorWithLsb(key, lsbs);
      return [key, xoredKey];
    }
  }

  /// Recovers the original key from the XORed data and least significant bytes
  String _recoverKey(String opData, List<int> lsbs) {
    Uint8List lsbBytes = Uint8List.fromList(lsbs);
    List<int> xorBytes = HEX.decode(opData);
    List<int> originalKeyBytes = [];
    for (int i = 0; i < xorBytes.length; i++) {
      originalKeyBytes.add(xorBytes[i] ^ lsbBytes[i]);
    }
    return HEX.encode(Uint8List.fromList(originalKeyBytes));
  }

  /// Retrieves encoded keys from addresses
  Future<List<String>> _getEncodedKeys(List<String> addrs) async {
    List res = await getEncodedKeys(addrs, digiassetNode);
    if (res.first) {
      EncodedKeyModel model = res[1];
      debug.log("RESULT -> ${model.result}");
      return model.result;
    } else {
      throw Exception("API ERROR! ${res[1]}");
    }
  }

  /// Verifies if the key index 'a' is in use
  Future<bool> _verifyAvalue(int a) async {
    List<String> addrs = [];
    for (int i = 0; i <= a + 1; i++) {
      HDWallet derived = mainWallet.derivePath("1000'/$coin'/$i'/256");
      addrs.add(derived.address!);
    }
    debug.log("Verify address list -> $addrs");
    List<String> encodedKeys = await _getEncodedKeys(addrs);
    if (encodedKeys.length == (addrs.length - 2)) {
      return true;
    } else {
      throw Exception("'a' value is already in use!");
    }
  }

  /// Pushes the encrypted key into a DigiByte transaction
  Future<Map<String, String>> generateEncryption(String privateKey, int keyNumber,
      String utxoWif, Map<String, dynamic> utxo) async {
    await _verifyAvalue(keyNumber);
    List<int> lsbs = _generatelsbs(keyNumber);
    List<String> data = _getOPData(privateKey, lsbs);

    String opData = data[1];

    String pKey = data[0];

    debug.log("OP DATA -> $opData");

    String getBack = _recoverKey(opData, lsbs);
    debug.log("getBack -> $getBack");

    if (getBack != pKey) {
      throw Exception("Private key doesn't match recovered private key");
    }

    // Inititate transaction to address, 1000h/ch/ah/256
    var rawTX = await _initiateTransaction(keyNumber, opData, utxoWif, utxo);

    return {"rawTX": rawTX, "opData": opData};
  }

  /// Converts a private key to WIF format
  String _toWif(String privKey, {bool compressed = true}) {
    if (privKey.length != 64) {
      throw ArgumentError('Invalid private key hex length (expected 64).');
    }
    Uint8List privateKeyBytes = Uint8List.fromList(HEX.decode(privKey));
    int versionByte = compressed ? 128 : 80;

    List<int> data = [versionByte] + privateKeyBytes;
    if (compressed) {
      data.add(0x01); // Compression byte
    }

    List<int> checksum =
        sha256.convert(sha256.convert(data).bytes).bytes.sublist(0, 4);
    data.addAll(checksum);

    var base58 = Base58Encoder(Base58CheckCodec.BITCOIN_ALPHABET);
    return base58.convert(data);
  }

  /// Initiates a transaction with the generated OP_RETURN data
  _initiateTransaction(int aVal, String opData, String utxoWif,
      Map<String, dynamic> utxo) async {
    HDWallet derived = mainWallet.derivePath("1000'/$coin'/$aVal'/256");
    String toAddress = derived.address!;
    String fromAddress = Wallet.fromWIF(utxoWif, digibyte).address!;
    int txValue = 650;
    int fee = 10000;
    UtxoModel model = UtxoModel.fromJson(utxo);

    final utxokeybag = ECPair.fromWIF(utxoWif, network: digibyte);

    // transaction building
    TransactionBuilder txb =
        TransactionBuilder(network: digibyte, maximumFeeRate: 100000);
    txb.setVersion(1);
    txb.addInput(model.txid, model.vout);
    txb.addOutput(toAddress, txValue);

    final scriptPubKey = sc.compile([OPS['OP_RETURN'], HEX.decode(opData)]);
    txb.addOutputData(scriptPubKey);

    int change = int.parse(model.value) - txValue - fee;
    if (change > 0) {
      txb.addOutput(fromAddress, change);
    }
    txb.sign(vin: 0, keyPair: utxokeybag);
    return txb.build().toHex();
  }

  /// Imports encoded keys from the DigiByte blockchain
  Future<List<String>> import() async {
    int batchSize = 20;
    int pos = 0;
    List<String> addrList = [];
    List<String> finalEncoded = [];
    while (true) {
      for (int i = pos; i < pos + batchSize; i++) {
        HDWallet derived = mainWallet.derivePath("1000'/$coin'/$i'/256");
        addrList.add(derived.address!);
      }
      debug.log("Verify address list -> $addrList");
      List<String> encodedKeys = await _getEncodedKeys(addrList);
      finalEncoded.addAll(encodedKeys);
      if (addrList.length != encodedKeys.length) {
        break;
      }
      pos += batchSize;
      addrList.clear();
    }
    return finalEncoded;
  }

  /// Decrypts the OP_RETURN data to retrieve the private key in wif format
  String decrypt(String opData, int keyNumber) {
    const prefix = '6a20';
    List<int> lsbs = _generatelsbs(keyNumber);
    Uint8List lsbBytes = Uint8List.fromList(lsbs);

    List<int> xorBytes = opData.startsWith(prefix)
        ? HEX.decode(opData.substring(prefix.length))
        : HEX.decode(opData);

    List<int> originalKeyBytes = [];
    for (int i = 0; i < xorBytes.length; i++) {
      originalKeyBytes.add(xorBytes[i] ^ lsbBytes[i]);
    }
    String getback = HEX.encode(Uint8List.fromList(originalKeyBytes));
    debug.log(getback);
    return _toWif(getback);
  }
}
