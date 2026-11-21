import React, { useEffect, useState } from 'react';
import { CheckCircle2, Fingerprint, ScanFace, ShieldX, X } from 'lucide-react';
import { BiometricMethod, Student } from '../types/attendance';

interface BiometricPromptModalProps {
  student: Student | null;
  onCancel: () => void;
  onVerified: (student: Student, method: BiometricMethod) => void;
}

export const BiometricPromptModal: React.FC<BiometricPromptModalProps> = ({
  student,
  onCancel,
  onVerified,
}) => {
  const [phase, setPhase] = useState<'prompt' | 'scanning' | 'matched' | 'rejected'>('prompt');
  const [selectedMethod, setSelectedMethod] = useState<'fingerprint' | 'face_id'>('fingerprint');

  useEffect(() => {
    if (student) {
      setPhase('prompt');
    }
  }, [student]);

  if (!student) return null;

  const triggerVerify = (method: 'fingerprint' | 'face_id') => {
    setSelectedMethod(method);
    setPhase('scanning');
    setTimeout(() => {
      setPhase('matched');
      setTimeout(() => {
        onVerified(student, method);
      }, 280);
    }, 340);
  };

  const triggerFailureTest = () => {
    setPhase('scanning');
    setTimeout(() => {
      setPhase('rejected');
    }, 340);
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-slate-950/65 backdrop-blur-sm p-0 sm:p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="biometric-prompt-title"
    >
      <div className="w-full sm:max-w-md rounded-t-3xl sm:rounded-2xl bg-white border border-slate-200 shadow-2xl p-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-xs font-medium text-slate-500">
              Hardware Biometric Prompt · local_auth (biometricOnly)
            </p>
            <h2 id="biometric-prompt-title" className="mt-1 text-lg font-bold text-slate-900">
              {student.firstName} {student.lastName}
            </h2>
            <p className="text-xs text-slate-500 font-mono tabular-nums">
              {student.studentCode} · Grade {student.gradeLevel} · Homeroom {student.homeroom}
            </p>
          </div>
          <button
            type="button"
            onClick={onCancel}
            className="min-h-[44px] min-w-[44px] flex items-center justify-center rounded-xl text-slate-400 hover:text-slate-700 hover:bg-slate-100 transition-colors"
            aria-label="Cancel biometric check"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        {/* Sensor Visual Stage */}
        <div className="my-6 flex flex-col items-center justify-center rounded-xl border border-slate-200 bg-slate-50 py-7 px-4 text-center">
          {phase === 'prompt' && (
            <>
              <div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-slate-900 text-white shadow-sm">
                {selectedMethod === 'fingerprint' ? (
                  <Fingerprint className="h-8 w-8" />
                ) : (
                  <ScanFace className="h-8 w-8" />
                )}
              </div>
              <p className="mt-3 text-sm font-semibold text-slate-900">
                Verify identity to check in
              </p>
              <p className="mt-1 text-xs text-slate-500 max-w-xs">
                Device passcode fallback is disabled. Only enrolled hardware biometrics can lock this attendance tile.
              </p>
            </>
          )}

          {phase === 'scanning' && (
            <>
              <div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-emerald-50 border border-emerald-200 text-emerald-700 animate-pulse">
                {selectedMethod === 'fingerprint' ? (
                  <Fingerprint className="h-8 w-8" />
                ) : (
                  <ScanFace className="h-8 w-8" />
                )}
              </div>
              <p className="mt-3 text-sm font-semibold text-slate-900">
                Reading secure enclave sensor...
              </p>
            </>
          )}

          {phase === 'matched' && (
            <>
              <div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-emerald-600 text-white">
                <CheckCircle2 className="h-8 w-8" />
              </div>
              <p className="mt-3 text-sm font-bold text-emerald-700">
                Biometric Match Confirmed
              </p>
              <p className="mt-0.5 text-xs text-slate-500">
                Writing local SQLite record and locking tile...
              </p>
            </>
          )}

          {phase === 'rejected' && (
            <>
              <div className="flex h-16 w-16 items-center justify-center rounded-2xl bg-red-600 text-white">
                <ShieldX className="h-8 w-8" />
              </div>
              <p className="mt-3 text-sm font-bold text-red-700">
                Biometric Mismatch (Returned False)
              </p>
              <p className="mt-1 text-xs text-slate-600 max-w-xs">
                Identity did not match enrolled template. No attendance record was written; tile remains unlocked.
              </p>
            </>
          )}
        </div>

        {/* Interactive Biometric Controls */}
        <div className="space-y-2.5">
          <div className="grid grid-cols-2 gap-2.5">
            <button
              type="button"
              disabled={phase === 'scanning' || phase === 'matched'}
              onClick={() => triggerVerify('fingerprint')}
              className="min-h-[48px] flex items-center justify-center gap-2 rounded-xl bg-slate-900 px-4 py-2.5 text-sm font-semibold text-white hover:bg-slate-800 disabled:opacity-60 active:scale-[0.98] transition-all"
            >
              <Fingerprint className="h-4 w-4" />
              <span className="whitespace-nowrap">Touch ID Match</span>
            </button>
            <button
              type="button"
              disabled={phase === 'scanning' || phase === 'matched'}
              onClick={() => triggerVerify('face_id')}
              className="min-h-[48px] flex items-center justify-center gap-2 rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-sm font-semibold text-slate-900 hover:bg-slate-50 disabled:opacity-60 active:scale-[0.98] transition-all"
            >
              <ScanFace className="h-4 w-4" />
              <span className="whitespace-nowrap">Face ID Match</span>
            </button>
          </div>

          <div className="flex items-center justify-between pt-1">
            <button
              type="button"
              disabled={phase === 'scanning' || phase === 'matched'}
              onClick={triggerFailureTest}
              className="min-h-[40px] px-2 text-xs font-medium text-red-700 hover:text-red-800 hover:underline disabled:opacity-50"
            >
              Simulate Non-Match / Spoof
            </button>
            <button
              type="button"
              onClick={onCancel}
              className="min-h-[40px] px-3 text-xs font-medium text-slate-600 hover:text-slate-900"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};
