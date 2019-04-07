import 'dart:async';
import 'dart:html';
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:CommonLib/Utility.dart";

import "formats/Formats.dart";
import "manifest/BundleManifest.dart";
import "resource.dart";

export "resource.dart";

abstract class Loader {
    static bool _initialised = false;
    static BundleManifest manifest;
    static final Map<String, Resource<dynamic>> _resources = <String, Resource<dynamic>>{};
    static final RegExp _slash = new RegExp(r"[\/]");
    static final RegExp _protocol = new RegExp(r"\w+:\/\/");

    /// The manifest is now optional and if you don't call to load it explicitly, it's totally ignored.
    static bool _usingManifest = false;

    static void init() {
        if (_initialised) { return; }
        _initialised = true;

        Formats.init();
    }

    static Future<T> getResource<T>(String path, {FileFormat<T, dynamic> format, bool bypassManifest = false, bool absoluteRoot = false}) async {
        init();
        if (_resources.containsKey(path)) {
            final Resource<dynamic> res = _resources[path];
            //if (res is Resource<T>) {
                if (res.object != null) {
                    return res.object;
                } else {
                    return res.addListener();
                }
            //} else {
            //    throw "Requested resource ($path) is an unexpected type: ${res.object.runtimeType}.";
            //}
        } else {
            if (_usingManifest && !bypassManifest) {
                if (manifest == null) {
                    await loadManifest();
                }

                final String bundle = manifest.getBundleForFile(path);

                if (bundle != null) {
                    await _loadBundle(bundle);
                    return _createResource(path).object;
                }
            }
            return _load(path, format: format, absoluteRoot: absoluteRoot);
        }
    }

    static Future<void> loadManifest() async {
        _usingManifest = true;
        manifest = await Loader.getResource("manifest/manifest.txt", format: Formats.manifest, bypassManifest: true);
    }

    static Resource<T> _createResource<T>(String path) {
        if (!_resources.containsKey(path)) {
            _resources[path] = new Resource<T>(path);
        }
        return _resources[path];
    }

    static Future<T> _load<T>(String path, {FileFormat<T, dynamic> format, bool absoluteRoot = false}) async {
        if(_resources.containsKey(path)) {

            // I guess we can put this check here too to eliminate the problem... I guess this makes sense?
            final Resource<dynamic> res = _resources[path];
            //if (res is Resource<T>) { // forget the type check for now until a better solution is implemented
                if (res.object != null) {
                    return res.object;
                } else {
                    return res.addListener();
                }
            //} else {
            //    throw "Requested resource ($path) is an unexpected type: ${res.object.runtimeType}.";
            //}

            //throw "Resource $path has already been requested for loading";
        }

        if (format == null) {
            final String extension = path.split(".").last;
            format = Formats.getFormatForExtension(extension);
        }

        final Resource<T> res = _createResource(path);

        format.requestObjectFromUrl(_getFullPath(path, absoluteRoot)).then(res.populate);

        return res.addListener();
    }

    /// Sets a resource at a specified path to an object, does not load a file
    static void assignResource<T>(T object, String path) {
        _createResource(path).object = object;
    }

    /// Removes a resource from the listings, and completes any waiting gets with an error state
    static void purgeResource(String path) {
        if (_resources.containsKey(path)) {
            final Resource<dynamic> r = _resources[path];
            for(final Completer<dynamic> c in r.listeners) {
                if (!c.isCompleted) {
                    c.completeError("Resource purged");
                }
            }
        }
        _resources.remove(path);
    }

    static Future<void> _loadBundle(String path) async {
        final Archive bundle = await Loader.getResource("$path.bundle", bypassManifest: true);

        final String dir = path.substring(0, path.lastIndexOf(_slash));

        final Completer<void> completer = new Completer<void>();
        final List<Future<dynamic>> fileFutures = <Future<dynamic>>[];

        for (final ArchiveFile file in bundle.files) {
            final String extension = file.name.split(".").last;
            final FileFormat<dynamic, dynamic> format = Formats.getFormatForExtension(extension);

            final String fullname = "$dir/${file.name}";

            if (_resources.containsKey(fullname)) {
                fileFutures.add(getResource(fullname));
                continue;
            }

            final Uint8List data = file.content;

            final Resource<dynamic> res = _createResource(fullname);
            fileFutures.add(res.addListener());

            format.fromBytes(data.buffer).then((dynamic thing) { format.read(thing).then(res.populate); });
        }

        Future.wait(fileFutures).then((List<dynamic> list) { completer.complete(); });

        return completer.future;
    }

    // JS loading extra special dom stuff

    static final Map<String, ScriptElement> _loadedScripts = <String, ScriptElement>{};

    static Future<ScriptElement> loadJavaScript(String path, [bool absoluteRoot = false]) async {
        if (_loadedScripts.containsKey(path)) {
            return _loadedScripts[path];
        }
        final Completer<ScriptElement> completer = new Completer<ScriptElement>();

        final ScriptElement script = new ScriptElement();
        document.head.append(script);
        script.onLoad.listen((Event e) => completer.complete(script));
        script.src = _getFullPath(path, absoluteRoot);

        return completer.future;
    }

    static String _getFullPath(String path, [bool absoluteRoot = false]) {
        if (path.startsWith(_protocol)) { // if this is a whole-ass URL just let it go direct
            return path;
        }
        
        // resolve package based urls... this isn't strictly necessary but it's nice
        if (path.startsWith("package:")) {
            path = "/packages/${path.substring(8)}";
        } else if (path.startsWith("/")) { // treat leading slashes as absolute root anyway
            absoluteRoot = true;
            path = path.substring(1);
        }

        if (absoluteRoot) {
            final String abspath = "${window.location.protocol}//${window.location.host}/$path";
            return abspath;
        }
        return PathUtils.adjusted(path);
    }

    static Element loadButton<T,U>(FileFormat<T,U> format, LoadButtonCallback<T> callback, {bool multiple = false, String caption = "Load file"}) {
        return FileFormat.loadButton<T, U>(format, callback, multiple: multiple, caption: caption);
    }

    static Element saveButton<T,U>(FileFormat<T,U> format, Generator<T> objectGetter, {String caption = "Save file", Generator<String> filename = FileFormat.defaultFilename}) {
        return FileFormat.saveButton<T, U>(format, objectGetter, caption: caption, filename: filename);
    }
}

class Asset<T> {
    T item;
    String path;

    Asset(String this.path);
    Asset.direct(T this.item);

    Future<T> getAsset() async {
        if (this.item != null) {
            return this.item;
        }
        else if (this.path != null) {
            return Loader.getResource(this.path);
        }
        return null;
    }
}