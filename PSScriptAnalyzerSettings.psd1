@{
  # Usado no CI:  Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
  # So severidade Error (os avisos de estilo, como Write-Host em script de console, nao barram).
  Severity     = @('Error')

  # Excecoes conscientes:
  # - Usuario/senha: os scripts recebem as credenciais do Firebird do mesmo jeito que gbak/isql
  #   e repassam ao processo filho por ISC_USER/ISC_PASSWORD (nunca na linha de comando).
  #   SecureString/PSCredential nao protegeria nada nesse caminho e quebraria o uso nao-interativo.
  ExcludeRules = @('PSAvoidUsingUsernameAndPasswordParams', 'PSAvoidUsingPlainTextForPassword')
}
