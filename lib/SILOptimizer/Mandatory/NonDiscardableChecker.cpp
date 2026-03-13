//===--- NonDiscardableChecker.cpp ----------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
///
/// A mandatory SIL pass that enforces the ~Discardable invariant:
/// values of ~Discardable type must be explicitly consumed and cannot be
/// implicitly destroyed. Any implicit destruction of a ~Discardable value
/// in non-dead-end code is flagged as an error.
///
/// Detection strategy:
/// - `destroy_addr` on a directly ~Discardable address → error
/// - `destroy_value` on a SILBoxType whose field is ~Discardable → check
///   if `begin_access [deinit]` consumed the contents before the box
///   was destroyed. If not, it's an implicit discard → error.
///
/// Context detection:
/// - Deinit context: function's DeclContext is a DestructorDecl
/// - Discard self context: function contains a DropDeinitInst
///
/// This pass runs after the MoveOnlyChecker, which has already ensured
/// ~Copyable (and thus ~Discardable) values have clean OSSA lifetimes.
///
//===----------------------------------------------------------------------===//

#define DEBUG_TYPE "sil-non-discardable-checker"

#include "swift/AST/Decl.h"
#include "swift/AST/DiagnosticsSIL.h"
#include "swift/AST/Types.h"
#include "swift/Basic/Assertions.h"
#include "swift/Basic/Feature.h"
#include "swift/SIL/SILArgument.h"
#include "swift/SIL/SILBasicBlock.h"
#include "swift/SIL/SILFunction.h"
#include "swift/SIL/SILInstruction.h"
#include "swift/SIL/SILModule.h"
#include "swift/SILOptimizer/Analysis/DeadEndBlocksAnalysis.h"
#include "swift/SILOptimizer/PassManager/Transforms.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Support/Debug.h"

using namespace swift;

//===----------------------------------------------------------------------===//
// MARK: Helpers
//===----------------------------------------------------------------------===//

/// Check whether a destroy_addr is part of an @inout mutation pattern.
///
/// Synthesized setters for fields on ~Discardable types (e.g. Token.x.setter)
/// take @inout Token and do:
///   destroy_addr %self      // destroy old struct
///   begin_access [modify] %self
///   store %newField to (struct_element_addr %self, #field)
///   end_access
/// This is a mutation — the caller still owns a valid Token afterward.
///
/// We must NOT suppress destroy_addr on local alloc_stack variables, because
/// reassignment (var t = Token(); t = Token()) genuinely discards the old value.
static bool isInoutMutationPattern(DestroyAddrInst *dai) {
  SILValue addr = dai->getOperand();

  // Only applies to @inout function arguments, not local alloc_stack.
  auto *arg = dyn_cast<SILFunctionArgument>(addr);
  if (!arg)
    return false;

  // Must be an indirect_inout parameter.
  if (arg->getArgumentConvention() != SILArgumentConvention::Indirect_Inout)
    return false;

  // Check that the address is re-initialized after the destroy_addr
  // (store or begin_access [modify] to the same address).
  auto *block = dai->getParent();
  bool pastDestroy = false;
  for (auto &inst : *block) {
    if (&inst == dai) {
      pastDestroy = true;
      continue;
    }
    if (!pastDestroy)
      continue;

    // Store directly to the address.
    if (auto *si = dyn_cast<StoreInst>(&inst)) {
      if (si->getDest() == addr)
        return true;
    }

    // begin_access [modify] on the address (setter writes through it).
    if (auto *bai = dyn_cast<BeginAccessInst>(&inst)) {
      if (bai->getOperand() == addr &&
          bai->getAccessKind() == SILAccessKind::Modify)
        return true;
    }

    // copy_addr [init] to the address.
    if (auto *cai = dyn_cast<CopyAddrInst>(&inst)) {
      if (cai->getDest() == addr)
        return true;
    }
  }

  return false;
}

/// Check whether the current function is a consuming method on a ~Discardable
/// type that has NO ~Discardable stored properties. In such methods, the
/// caller's act of calling the consuming method IS the explicit consumption.
///
/// When the type HAS ~Discardable stored properties, the consuming method
/// body must explicitly consume each one — destroying self would implicitly
/// discard them.
static bool isConsumingMethodOfNonDiscardableType(SILFunction *fn,
                                                   bool leafOnly) {
  auto *dc = fn->getDeclContext();
  if (!dc)
    return false;

  auto *funcDecl = dyn_cast_or_null<FuncDecl>(dc->getAsDecl());
  if (!funcDecl)
    return false;

  // Must be a consuming method.
  if (funcDecl->getSelfAccessKind() != SelfAccessKind::Consuming)
    return false;

  // Check the self type is ~Discardable via the SIL function's convention.
  auto fnTy = fn->getLoweredFunctionType();
  if (!fnTy->hasSelfParam())
    return false;
  auto selfParam = fnTy->getSelfParameter();
  auto selfSILTy = SILType::getPrimitiveObjectType(
      selfParam.getInterfaceType());
  if (!selfSILTy.isNonDiscardable())
    return false;

  if (leafOnly) {
    // Check if the type has any ~Discardable stored properties.
    // If so, we can't suppress — those fields need explicit consumption.
    CanType selfCanTy = selfSILTy.getASTType();
    if (auto *nominal = selfCanTy->getAnyNominal()) {
      for (auto *member : nominal->getMembers()) {
        if (auto *var = dyn_cast<VarDecl>(member)) {
          if (!var->hasStorage())
            continue;
          auto fieldTy = var->getTypeInContext();
          if (fieldTy &&
              SILType::getPrimitiveObjectType(fieldTy->getCanonicalType())
                  .isNonDiscardable())
            return false;
        }
      }
    }
  }

  return true;
}

/// Check whether a SIL type is directly ~Discardable (not wrapped in a box).
static bool isNonDiscardableSILType(SILType ty) {
  SILType objectTy = ty.getObjectType();
  return objectTy.isNonDiscardable();
}

/// Check whether a SIL type contains any ~Discardable stored properties
/// (even if the type itself is not ~Discardable).
/// Only applies to value types (structs/enums). For classes, the deinit
/// is responsible for consuming fields — callers just release the reference.
static bool containsNonDiscardableField(SILType ty) {
  CanType canTy = ty.getObjectType().getASTType();
  // Class references are managed by deinits, not by callers.
  if (canTy->getClassOrBoundGenericClass())
    return false;
  auto *nominal = canTy->getAnyNominal();
  if (!nominal)
    return false;
  for (auto *member : nominal->getMembers()) {
    if (auto *var = dyn_cast<VarDecl>(member)) {
      if (!var->hasStorage())
        continue;
      auto fieldTy = var->getTypeInContext();
      if (fieldTy &&
          SILType::getPrimitiveObjectType(fieldTy->getCanonicalType())
              .isNonDiscardable())
        return true;
    }
  }
  return false;
}

/// Check whether a SIL type is ~Discardable OR contains ~Discardable fields.
static bool isOrContainsNonDiscardable(SILType ty) {
  return isNonDiscardableSILType(ty) || containsNonDiscardableField(ty);
}

/// Check whether a SIL type is a SILBoxType containing a ~Discardable field.
static bool isBoxedNonDiscardableType(SILType ty, const SILFunction *fn) {
  if (!ty.is<SILBoxType>())
    return false;
  SILType fieldTy = ty.getSILBoxFieldType(fn);
  return fieldTy.isNonDiscardable();
}

/// Check access patterns on a projected box address.
/// Returns true if there is a [deinit] access but NO subsequent [modify]
/// (reinit). Returns false if the value was never consumed or was
/// re-initialized after consumption.
static bool checkProjectBoxConsumed(ProjectBoxInst *pbi) {
  bool hasDeinit = false;
  bool hasModify = false;

  for (auto *projUse : pbi->getUses()) {
    auto *projUser = projUse->getUser();
    if (auto *bai = dyn_cast<BeginAccessInst>(projUser)) {
      if (bai->getAccessKind() == SILAccessKind::Deinit)
        hasDeinit = true;
      if (bai->getAccessKind() == SILAccessKind::Modify)
        hasModify = true;
    }
  }

  // Consumed only if there's a [deinit] without a [modify] (reinit).
  return hasDeinit && !hasModify;
}

/// For a destroy_value on a box, check if the box's contents were consumed
/// and NOT re-initialized. If consumed and not re-initialized, the box is
/// empty at destruction time (OK). Otherwise, it still contains a
/// ~Discardable value (ERROR).
static bool boxContentsWereConsumed(SILValue boxValue) {
  // Walk through begin_borrow to find project_box uses.
  for (auto *use : boxValue->getUses()) {
    auto *user = use->getUser();

    // Look through begin_borrow.
    if (auto *bbi = dyn_cast<BeginBorrowInst>(user)) {
      for (auto *borrowUse : bbi->getUses()) {
        auto *borrowUser = borrowUse->getUser();
        if (auto *pbi = dyn_cast<ProjectBoxInst>(borrowUser)) {
          if (checkProjectBoxConsumed(pbi))
            return true;
        }
      }
    }

    // Also handle direct project_box (without begin_borrow).
    if (auto *pbi = dyn_cast<ProjectBoxInst>(user)) {
      if (checkProjectBoxConsumed(pbi))
        return true;
    }
  }

  return false;
}

/// Walk through forwarding instructions to find the root value.
static SILValue walkToRoot(SILValue value) {
  while (true) {
    if (auto *inst = value->getDefiningInstruction()) {
      if (auto *bbi = dyn_cast<BeginBorrowInst>(inst)) {
        value = bbi->getOperand();
        continue;
      }
      if (auto *mvi = dyn_cast<MoveValueInst>(inst)) {
        value = mvi->getOperand();
        continue;
      }
      if (auto *cvi = dyn_cast<CopyValueInst>(inst)) {
        value = cvi->getOperand();
        continue;
      }
      if (auto *pbi = dyn_cast<ProjectBoxInst>(inst)) {
        value = pbi->getOperand();
        continue;
      }
      if (auto *bai = dyn_cast<BeginAccessInst>(inst)) {
        value = bai->getOperand();
        continue;
      }
    }
    break;
  }
  return value;
}

/// Check whether a destroyed value traces back to `self`.
/// After MoveOnlyChecker, self is on alloc_stack named "self".
static bool isSelfValue(SILValue value) {
  SILValue root = walkToRoot(value);

  // Direct argument named "self".
  if (auto *arg = dyn_cast<SILArgument>(root)) {
    if (auto *decl = arg->getDecl())
      return decl->getBaseIdentifier().str() == "self";
  }

  // alloc_box/alloc_stack for "self".
  if (auto *inst = root->getDefiningInstruction()) {
    if (auto *abi = dyn_cast<AllocBoxInst>(inst)) {
      if (auto *decl = abi->getDecl())
        return decl->getBaseIdentifier().str() == "self";
    }
    if (auto *asi = dyn_cast<AllocStackInst>(inst)) {
      if (auto *decl = asi->getDecl())
        return decl->getBaseIdentifier().str() == "self";
    }
  }
  return false;
}

/// Information about the source of a ~Discardable value for diagnostics.
struct DiagInfo {
  StringRef name;
  SourceLoc loc;
  bool isProperty = false;
};

/// Find the name and declaration source location for a value.
/// Like MoveOnlyChecker, we emit at the alloc_box/argument location,
/// not the destroy site.
static DiagInfo getDiagInfo(SILValue value, SILInstruction &fallback) {
  SILValue root = walkToRoot(value);
  DiagInfo info;
  info.loc = fallback.getLoc().getSourceLoc();

  // Check if the value is an argument with a name.
  if (auto *arg = dyn_cast<SILArgument>(root)) {
    if (auto *decl = arg->getDecl()) {
      info.name = decl->getBaseIdentifier().str();
      info.loc = decl->getLoc();
    }
    return info;
  }

  // Check alloc_box/alloc_stack for VarDecl info.
  if (auto *inst = root->getDefiningInstruction()) {
    if (auto *asi = dyn_cast<AllocStackInst>(inst)) {
      if (auto *decl = asi->getDecl()) {
        info.name = decl->getBaseIdentifier().str();
        info.loc = asi->getLoc().getSourceLoc();
      }
    } else if (auto *abi = dyn_cast<AllocBoxInst>(inst)) {
      if (auto *decl = abi->getDecl()) {
        info.name = decl->getBaseIdentifier().str();
        info.loc = abi->getLoc().getSourceLoc();
      }
    } else if (auto *sei = dyn_cast<StructElementAddrInst>(inst)) {
      if (auto *decl = sei->getField()) {
        info.name = decl->getBaseIdentifier().str();
        info.loc = sei->getLoc().getSourceLoc();
        if (info.loc.isInvalid()) {
          info.loc = decl->getLoc();
        }
        info.isProperty = true;
      }
    } else if (auto *rei = dyn_cast<RefElementAddrInst>(inst)) {
      if (auto *decl = rei->getField()) {
        info.name = decl->getBaseIdentifier().str();
        info.loc = rei->getLoc().getSourceLoc();
        if (info.loc.isInvalid()) {
          info.loc = decl->getLoc();
        }
        info.isProperty = true;
      }
    }
  }

  return info;
}

//===----------------------------------------------------------------------===//
// MARK: Context detection
//===----------------------------------------------------------------------===//

/// Determine if the SIL function is a deinit (destroying destructor).
static bool isDeinitFunction(SILFunction *fn) {
  if (auto *dc = fn->getDeclContext()) {
    if (auto *decl = dc->getAsDecl()) {
      return isa<DestructorDecl>(decl);
    }
  }
  return false;
}

/// Determine if the SIL function contains a DropDeinitInst (discard self).
static bool hasDropDeinitInst(SILFunction *fn) {
  for (auto &block : *fn) {
    for (auto &inst : block) {
      if (isa<DropDeinitInst>(&inst))
        return true;
    }
  }
  return false;
}

/// Diagnostic context for the NonDiscardableChecker.
enum class DiagContext {
  /// Regular local scope — value must be consumed before going out of scope.
  LocalScope,
  /// Deinit body — stored property must be consumed before deinit exits.
  Deinit,
  /// Consuming method with discard self — stored property must be consumed
  /// before discard self.
  DiscardSelf,
};

//===----------------------------------------------------------------------===//
// MARK: Pass
//===----------------------------------------------------------------------===//

namespace {

class NonDiscardableCheckerPass : public SILFunctionTransform {
  void run() override {
    auto *fn = getFunction();

    // Don't rerun diagnostics on deserialized functions.
    if (fn->wasDeserializedCanonical())
      return;

    // Only run on Raw SIL.
    if (fn->getModule().getStage() != SILStage::Raw)
      return;

    // Gate behind the experimental feature flag.
    auto &ctx = fn->getModule().getASTContext();
    if (!ctx.LangOpts.hasFeature(Feature::NonDiscardableTypes))
      return;

    LLVM_DEBUG(llvm::dbgs() << "===> NonDiscardableChecker. Visiting: "
                            << fn->getName() << '\n');

    // Determine the diagnostic context.
    DiagContext diagCtx = DiagContext::LocalScope;
    if (isDeinitFunction(fn)) {
      diagCtx = DiagContext::Deinit;
      LLVM_DEBUG(llvm::dbgs() << "  Context: deinit\n");
    } else if (hasDropDeinitInst(fn)) {
      diagCtx = DiagContext::DiscardSelf;
      LLVM_DEBUG(llvm::dbgs() << "  Context: discard self\n");
    }

    // Check if this is a consuming method of a ~Discardable type.
    // In such methods, destroying `self` is OK — the caller's act of
    // calling the consuming method IS the explicit consumption.
    bool isConsumingSelfLeaf = isConsumingMethodOfNonDiscardableType(fn, /*leafOnly=*/true);
    bool isConsumingSelfAny = isConsumingMethodOfNonDiscardableType(fn, /*leafOnly=*/false);

    auto *deba = getAnalysis<DeadEndBlocksAnalysis>();
    auto *deadEndBlocks = deba->get(fn);

    for (auto &block : *fn) {
      // Skip dead-end blocks — paths that terminate in
      // fatalError()/unreachable trivially satisfy the must-consume rule.
      if (deadEndBlocks->isDeadEnd(&block))
        continue;

      for (auto &inst : block) {
        // Case 1: destroy_addr on a ~Discardable type or a type containing
        // ~Discardable stored properties.
        if (auto *dai = dyn_cast<DestroyAddrInst>(&inst)) {
          SILType ty = dai->getOperand()->getType();

          bool directlyND = isNonDiscardableSILType(ty);
          bool containsND = containsNonDiscardableField(ty);

          if (!directlyND && !containsND)
            continue;

          // Skip @inout mutation patterns (setter: destroy old + store new).
          // The caller still owns a valid value after the function returns.
          if (isInoutMutationPattern(dai))
            continue;

          // Skip destroy_addr of self in consuming methods of leaf
          // ~Discardable types (no ~Discardable stored properties).
          // Types WITH ND fields fall through to the per-field path.
          if (isConsumingSelfLeaf && isSelfValue(dai->getOperand()) && !containsND)
            continue;

          // If the type has a user-defined deinit and is not directly
          // ~Discardable, destroying it is fine — its deinit body handles
          // field consumption (checked when the deinit is analyzed).
          if (!directlyND && ty.isValueTypeWithDeinit())
            continue;

          if (containsND &&
              (diagCtx != DiagContext::LocalScope || isConsumingSelfAny)) {
            // In deinit/consuming-method context: emit per-field diagnostics
            // so the user knows which specific field needs consuming.
            CanType canTy = ty.getObjectType().getASTType();
            if (auto *nominal = canTy->getAnyNominal()) {
              for (auto *member : nominal->getMembers()) {
                auto *var = dyn_cast<VarDecl>(member);
                if (!var || !var->hasStorage())
                  continue;
                auto fieldTy = var->getTypeInContext();
                if (!fieldTy)
                  continue;
                auto fieldSILTy = SILType::getPrimitiveObjectType(
                    fieldTy->getCanonicalType());
                if (!fieldSILTy.isNonDiscardable())
                  continue;

                DiagInfo info;
                info.name = var->getBaseIdentifier().str();
                info.loc = dai->getLoc().getSourceLoc();
                if (info.loc.isInvalid())
                  info.loc = var->getLoc();
                info.isProperty = true;

                LLVM_DEBUG(llvm::dbgs()
                           << "  Found implicit discard of ND field '"
                           << info.name << "' at: " << inst << '\n');

                emitDiagnostic(ctx, info, diagCtx);
              }
            }
          } else {
            // Directly ~Discardable with no ~Discardable fields:
            // emit value-level diagnostic.
            auto info = getDiagInfo(dai->getOperand(), inst);
            if (info.name.empty())
              info.name = "<anonymous>";

            LLVM_DEBUG(llvm::dbgs()
                       << "  Found implicit discard (destroy_addr) of '"
                       << info.name << "' at: " << inst << '\n');

            emitDiagnostic(ctx, info, diagCtx);
          }
          continue;
        }

        // Case 2: destroy_value on a SILBoxType containing ~Discardable.
        if (auto *dvi = dyn_cast<DestroyValueInst>(&inst)) {
          SILType ty = dvi->getOperand()->getType();

          // Skip destroy_value on DropDeinitInst results —
          // drop_deinit + destroy_value is the SIL lowering of
          // `discard self` or class deinit epilog, which IS explicit.
          if (auto *defInst = dvi->getOperand()->getDefiningInstruction()) {
            if (isa<DropDeinitInst>(defInst))
              continue;
          }

          bool isImplicitDiscard = false;

          if (isBoxedNonDiscardableType(ty, fn)) {
            // Check if the box contents were consumed and not re-initialized.
            if (!boxContentsWereConsumed(dvi->getOperand()))
              isImplicitDiscard = true;
          } else if (isNonDiscardableSILType(ty)) {
            // Skip destroy_value of enum values that were consumed by
            // switch_enum. After a switch, the enum is destructured and
            // each case handles its own payload. The destroy in the
            // non-matching case branch is just cleanup of the enum shell.
            {
              SILValue val = dvi->getOperand();
              bool switchConsumed = false;
              for (auto *use : val->getUses()) {
                if (isa<SwitchEnumInst>(use->getUser()) ||
                    isa<UncheckedEnumDataInst>(use->getUser())) {
                  switchConsumed = true;
                  break;
                }
              }
              if (switchConsumed)
                continue;
            }

            // Case 3: destroy_value on a direct ~Discardable value
            // (e.g. from load [copy] + move_value in inout handling).
            isImplicitDiscard = true;
          } else if (containsNonDiscardableField(ty)) {
            // destroy_value on a type containing ~Discardable fields.
            isImplicitDiscard = true;
          }

          if (!isImplicitDiscard)
            continue;

          auto info = getDiagInfo(dvi->getOperand(), inst);
          if (info.name.empty())
            info.name = "<anonymous>";

          LLVM_DEBUG(llvm::dbgs()
                     << "  Found implicit discard (destroy_value) of '"
                     << info.name << "' at: " << inst << '\n');

          emitDiagnostic(ctx, info, diagCtx);
          continue;
        }
      }
    }
  }

  /// Emit the appropriate diagnostic based on context.
  void emitDiagnostic(ASTContext &ctx, const DiagInfo &info,
                      DiagContext diagCtx) {
    if (info.isProperty) {
      switch (diagCtx) {
      case DiagContext::Deinit:
        ctx.Diags.diagnose(info.loc,
                           diag::sil_nondiscardable_unconsumed_in_deinit,
                           info.name);
        return;
      case DiagContext::DiscardSelf:
        ctx.Diags.diagnose(info.loc,
                           diag::sil_nondiscardable_leaked_by_discard_self,
                           info.name);
        return;
      case DiagContext::LocalScope:
        // A property in local scope context — use the general diagnostic.
        break;
      }
    }
    ctx.Diags.diagnose(info.loc, diag::sil_nondiscardable_unconsumed,
                       info.name);
  }
};

} // namespace

SILTransform *swift::createNonDiscardableChecker() {
  return new NonDiscardableCheckerPass();
}
