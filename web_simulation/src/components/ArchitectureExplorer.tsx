import React, { useMemo, useState } from 'react';
import { Check, Copy, Download, FileCode2, FolderTree } from 'lucide-react';
import { FLUTTER_SUPABASE_FILES, SourceFileEntry } from '../data/flutterSourceBundle';

export const ArchitectureExplorer: React.FC = () => {
  const [selectedCategory, setSelectedCategory] = useState<'All' | SourceFileEntry['category']>('All');
  const [selectedPath, setSelectedPath] = useState<string>(FLUTTER_SUPABASE_FILES[0].path);
  const [copiedPath, setCopiedPath] = useState<string | null>(null);

  const filteredFiles = useMemo(() => {
    if (selectedCategory === 'All') return FLUTTER_SUPABASE_FILES;
    return FLUTTER_SUPABASE_FILES.filter((f) => f.category === selectedCategory);
  }, [selectedCategory]);

  const activeFile = useMemo(
    () =>
      FLUTTER_SUPABASE_FILES.find((f) => f.path === selectedPath) ??
      filteredFiles[0] ??
      FLUTTER_SUPABASE_FILES[0],
    [selectedPath, filteredFiles],
  );

  const handleCopy = async () => {
    await navigator.clipboard.writeText(activeFile.content);
    setCopiedPath(activeFile.path);
    setTimeout(() => setCopiedPath(null), 1800);
  };

  const handleDownloadFile = () => {
    const filename = activeFile.path.split('/').pop() ?? 'lectureguard_file.txt';
    const blob = new Blob([activeFile.content], { type: 'text/plain;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  };

  const categories: Array<'All' | SourceFileEntry['category']> = [
    'All',
    'Database & RLS',
    'Security & Biometrics',
    'State & Services',
    'Flutter UI Screens',
    'Project Config',
  ];

  return (
    <div className="space-y-6">
      <div className="rounded-2xl border border-slate-200 bg-white p-6">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
          <div>
            <p className="text-xs text-slate-500">
              Flutter 3 · Riverpod · sqflite (WAL) · local_auth · flutter_secure_storage · Supabase PostgreSQL RLS
            </p>
            <h1 className="mt-1 text-2xl font-bold tracking-tight text-slate-900">
              Production Flutter &amp; Supabase Architecture
            </h1>
          </div>

          <div className="flex items-center gap-1 p-1 bg-slate-100 rounded-xl overflow-x-auto">
            {categories.map((cat) => (
              <button
                key={cat}
                type="button"
                onClick={() => setSelectedCategory(cat)}
                className={`px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors whitespace-nowrap shrink-0 ${
                  selectedCategory === cat
                    ? 'bg-white text-slate-900 shadow-sm'
                    : 'text-slate-600 hover:text-slate-900'
                }`}
              >
                {cat}
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6 items-start">
        {/* Folder Tree Sidebar */}
        <aside className="lg:col-span-4 rounded-2xl border border-slate-200 bg-white overflow-hidden">
          <div className="px-4 py-3 border-b border-slate-200 bg-slate-50 flex items-center gap-2 text-xs font-bold text-slate-700">
            <FolderTree className="h-4 w-4 text-slate-500" />
            <span>Repository Structure ({filteredFiles.length} files)</span>
          </div>
          <div className="divide-y divide-slate-100 max-h-[640px] overflow-y-auto">
            {filteredFiles.map((file) => {
              const isSelected = file.path === activeFile.path;
              return (
                <button
                  key={file.path}
                  type="button"
                  onClick={() => setSelectedPath(file.path)}
                  className={`w-full text-left px-4 py-3 transition-colors flex items-start gap-2.5 ${
                    isSelected ? 'bg-slate-900 text-white' : 'hover:bg-slate-50 text-slate-800'
                  }`}
                >
                  <FileCode2
                    className={`h-4 w-4 mt-0.5 shrink-0 ${
                      isSelected ? 'text-emerald-400' : 'text-slate-400'
                    }`}
                  />
                  <div className="min-w-0 flex-1">
                    <p className="text-xs font-mono font-semibold truncate">{file.path}</p>
                    <p
                      className={`mt-1 text-[11px] line-clamp-2 ${
                        isSelected ? 'text-slate-300' : 'text-slate-500'
                      }`}
                    >
                      {file.summary}
                    </p>
                  </div>
                </button>
              );
            })}
          </div>
        </aside>

        {/* Source Viewer */}
        <div className="lg:col-span-8 rounded-2xl border border-slate-200 bg-slate-950 text-slate-100 overflow-hidden">
          <div className="px-5 py-3.5 border-b border-slate-800 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
            <div className="min-w-0">
              <p className="text-xs font-mono font-semibold text-emerald-400 truncate">
                {activeFile.path}
              </p>
              <p className="mt-0.5 text-xs text-slate-400 truncate">{activeFile.summary}</p>
            </div>
            <div className="flex items-center gap-2 shrink-0">
              <button
                type="button"
                onClick={handleCopy}
                className="min-h-[36px] inline-flex items-center gap-1.5 rounded-lg border border-slate-700 bg-slate-900 px-3 text-xs font-semibold text-slate-200 hover:bg-slate-800 transition-colors whitespace-nowrap"
              >
                {copiedPath === activeFile.path ? (
                  <>
                    <Check className="h-3.5 w-3.5 text-emerald-400" />
                    <span>Copied</span>
                  </>
                ) : (
                  <>
                    <Copy className="h-3.5 w-3.5" />
                    <span>Copy Code</span>
                  </>
                )}
              </button>
              <button
                type="button"
                onClick={handleDownloadFile}
                className="min-h-[36px] inline-flex items-center gap-1.5 rounded-lg bg-white px-3 text-xs font-semibold text-slate-900 hover:bg-slate-100 transition-colors whitespace-nowrap"
              >
                <Download className="h-3.5 w-3.5" />
                <span>Download</span>
              </button>
            </div>
          </div>
          <pre className="p-5 text-xs leading-relaxed font-mono text-slate-200 overflow-x-auto max-h-[600px] overflow-y-auto">
            <code>{activeFile.content}</code>
          </pre>
        </div>
      </div>
    </div>
  );
};
