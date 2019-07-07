;;; comp.el --- compilation of Lisp code into native code -*- lexical-binding: t -*-

;; Copyright (C) 2019 Free Software Foundation, Inc.

;; Keywords: lisp
;; Package: emacs

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'bytecomp)
(eval-when-compile (require 'cl-lib))

(defgroup comp nil
  "Emacs Lisp native compiler."
  :group 'lisp)

(defconst comp-debug t)

(defconst comp-passes '(comp-recuparate-lap
                        comp-limplify)
  "Passes to be executed in order.")

(defconst comp-known-ret-types '((Fcons . cons)))

(cl-defstruct comp-args
  mandatory nonrest rest)

(cl-defstruct (comp-func (:copier nil))
  "Internal rapresentation for a function."
  (symbol-name nil
   :documentation "Function symbol's name")
  (func nil
   :documentation "Original form")
  (byte-func nil
   :documentation "Byte compiled version")
  (ir nil
      :documentation "Current intermediate rappresentation")
  (args nil :type 'comp-args))

(cl-defstruct (comp-mvar (:copier nil))
  "A meta-variable being a slot in the meta-stack."
  (slot nil :type fixnum
        :documentation "Slot position")
  (const-vld nil
             :documentation "Valid signal for the following slot")
  (constant nil
            :documentation "When const-vld non nil this is used for constant
 propagation")
  (type nil
        :documentation "When non nil is used for type propagation"))

(cl-defstruct (comp-limple-frame (:copier nil))
  "A LIMPLE func."
  (sp 0 :type 'fixnum
      :documentation "Current stack pointer")
  (frame nil :type 'vector
         :documentation "Meta-stack used to flat LAP"))

(defun comp-decrypt-lambda-list (x)
  "Decript lambda list X."
  (make-comp-args :rest (not (= (logand x 128) 0))
                  :mandatory (logand x 127)
                  :nonrest (ash x -8)))

(defun comp-recuparate-lap (ir)
  "Byte compile and recuparate LAP rapresentation for IR."
  ;; FIXME block timers here, otherwise we could spill the wrong LAP.
  (setf (comp-func-byte-func ir)
        (byte-compile (comp-func-symbol-name ir)))
  (when comp-debug
    (cl-prettyprint byte-compile-lap-output))
  (setf (comp-func-args ir)
        (comp-decrypt-lambda-list (aref (comp-func-byte-func ir) 0)))
  (setf (comp-func-ir ir) byte-compile-lap-output)
  ir)

(defmacro comp-sp ()
  "Current stack pointer."
  '(comp-limple-frame-sp frame))

(defmacro comp-slot-n (n)
  "Slot N into the meta-stack."
  `(aref (comp-limple-frame-frame frame) ,n))

(defmacro comp-slot ()
  "Current slot into the meta-stack pointed by sp."
  '(comp-slot-n (comp-sp)))

(defmacro comp-slot-next ()
  "Slot into the meta-stack pointed by sp + 1."
  '(comp-slot-n (1+ (comp-sp))))

(defmacro comp-push-call (x)
  "Push call X into frame."
  `(let ((src-slot ,x))
     (cl-incf (comp-sp))
     (setf (comp-slot)
           (make-comp-mvar :slot (comp-sp)
                           :type (alist-get (second src-slot)
                                            comp-known-ret-types)))
     (push (list '=call (comp-slot) src-slot) ir)))

(defmacro comp-push-slot-n (n)
  "Push slot number N into frame."
  `(let ((src-slot (comp-slot-n ,n)))
     (cl-incf (comp-sp))
     (setf (comp-slot)
           (copy-sequence src-slot))
     (setf (comp-mvar-slot (comp-slot)) (comp-sp))
     (push (list '=slot (comp-slot) src-slot) ir)))

(defmacro comp-push-const (x)
  "Push X into frame.
X value is known at compile time."
  `(let ((val ,x))
     (cl-incf (comp-sp))
     (setf (comp-slot) (make-comp-mvar :slot (comp-sp)
                                       :const-vld t
                                       :constant val))
     (push (list '=const (comp-slot) val) ir)))

(defmacro comp-pop (n)
  "Pop N elements from the meta-stack."
  `(cl-decf (comp-sp) ,n))

(defun comp-limplify-lap-inst (inst frame ir)
  "Limplify LAP instruction INST in current FRAME accumulating in IR.
Return the new head."
  (cl-flet ((do-list (n)
               (comp-pop 1)
               (comp-push-call `(call Fcons ,(comp-slot-next) nil))
               (dotimes (_ (1- n))
                 (comp-pop 2)
                 (comp-push-call `(call Fcons
                                        ,(comp-slot-next)
                                        ,(comp-slot-n (+ 2 (comp-sp))))))))
    (let ((op (car inst)))
      (pcase op
        ('byte-dup
         (comp-push-slot-n (comp-sp)))
        ('byte-varref
         (comp-push-call `(call Fsymbol_value ,(second inst))))
        ('byte-constant
         (comp-push-const (second inst)))
        ('byte-stack-ref
         (comp-push-slot-n (- (comp-sp) (cdr inst))))
        ('byte-plus
         (comp-pop 2)
         (comp-push-call `(callref Fplus 2 ,(comp-sp))))
        ('byte-car
         (comp-pop 1)
         (comp-push-call `(call Fcar ,(comp-sp))))
        ('byte-cdr
         (comp-pop 1)
         (comp-push-call `(call Fcdr ,(comp-sp))))
        ('byte-list1
         (do-list 1))
        ('byte-list2
         (do-list 2))
        ('byte-list3
         (do-list 3))
        ('byte-list4
         (do-list 4))
        ('byte-return
         `(return ,(comp-slot)))
        (_ (error "Unexpected LAP op %s" (symbol-name op))))))
  ir)

(defun comp-limplify (ir)
  "Given IR and return LIMPLE."
  (let* ((frame-size (aref (comp-func-byte-func ir) 3))
         (frame (make-comp-limple-frame
                 :sp -1
                 :frame (let ((v (make-vector frame-size nil)))
                          (cl-loop for i below frame-size
                                   do (aset v i (make-comp-mvar :slot i)))
                          v)))
         (limple-ir ()))
    ;; Prologue
    (push '(BLOCK prologue) limple-ir)
    (cl-loop for i below (comp-args-mandatory (comp-func-args ir))
             do (progn
                  (cl-incf (comp-sp))
                  (push `(=par ,(comp-slot) ,i) limple-ir)))
    (push '(BLOCK body) limple-ir)
    (mapc (lambda (inst)
            (setq limple-ir (comp-limplify-lap-inst inst frame limple-ir)))
          (comp-func-ir ir))
    (setq limple-ir (reverse limple-ir))
    (setf (comp-func-ir ir) limple-ir)
    (when comp-debug
      (cl-prettyprint (comp-func-ir ir)))
    ir))

(defun native-compile (fun)
  "FUN is the function definition to be compiled to native code."
  (unless lexical-binding
    (error "Can't compile a non lexical binded function"))
  (if-let ((f (symbol-function fun)))
      (progn
        (when (byte-code-function-p f)
          (error "Can't native compile an already bytecompiled function"))
        (cl-loop with ir = (make-comp-func :symbol-name fun
                                           :func f)
                 for pass in comp-passes
                 do (funcall pass ir)
                 finally return ir))
    (error "Trying to native compile not a function")))

(provide 'comp)

;;; comp.el ends here
