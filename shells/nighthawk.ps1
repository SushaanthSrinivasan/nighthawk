# nighthawk PowerShell plugin
#
# Architecture:
#   Registers a PSReadLine predictor that communicates with the
#   nighthawk daemon over a named pipe.
#
# Install:
#   Add to $PROFILE: . /path/to/nighthawk.ps1
#
# Contract:
#   1. Connect to daemon named pipe (\\.\pipe\nighthawk)
#   2. Implement ICommandPredictor interface via PSReadLine
#   3. On prediction request: send CompletionRequest JSON
#   4. Read CompletionResponse JSON
#   5. PSReadLine handles ghost text rendering natively
#
# Note: PSReadLine predictors have a 20ms timeout, so only
# Tier 0 (history) and Tier 1 (specs) are viable here.

# TODO: Implement PSReadLine predictor
# This requires a compiled C# class implementing ICommandPredictor,
# or using Set-PSReadLineOption -PredictionSource with a custom handler.

# Placeholder: Register inline prediction view
# Set-PSReadLineOption -PredictionViewStyle InlineView
