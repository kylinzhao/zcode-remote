package dev.zcode.remote

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import dev.zcode.remote.databinding.ActivityAccountEditBinding
import java.util.UUID

/** 手动添加/编辑额度账号（扫码导入之外的兜底）。 */
class AccountEditActivity : Activity() {

    private lateinit var binding: ActivityAccountEditBinding
    private var editingId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityAccountEditBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.btnBack.setOnClickListener { finish() }

        editingId = intent.getStringExtra(EXTRA_ID)
        if (editingId != null) {
            val existing = QuotaAccountStore.load(this).firstOrNull { it.id == editingId }
            if (existing == null) {
                finish(); return
            }
            binding.tvTitle.setText(R.string.quota_edit_title)
            binding.inputName.setText(existing.name)
            binding.inputKey.setText(existing.apiKey.orEmpty())
            binding.inputJwt.setText(existing.jwt.orEmpty())
            binding.inputOrg.setText(existing.teamOrg.orEmpty())
            binding.inputProj.setText(existing.teamProj.orEmpty())
            binding.btnDelete.visibility = android.view.View.VISIBLE
            binding.btnDelete.setOnClickListener { confirmDelete() }
        }

        binding.btnSave.setOnClickListener { save() }
    }

    private fun confirmDelete() {
        val id = editingId ?: return
        AlertDialog.Builder(this)
            .setTitle(R.string.quota_delete_title)
            .setMessage(R.string.quota_delete_confirm)
            .setPositiveButton(R.string.menu_delete) { _, _ ->
                QuotaAccountStore.remove(this, id)
                finish()
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun save() {
        val key = binding.inputKey.text?.toString()?.trim().orEmpty()
        val jwt = binding.inputJwt.text?.toString()?.trim().orEmpty()
        if (key.isEmpty() && jwt.isEmpty()) {
            Toast.makeText(this, R.string.quota_need_credential, Toast.LENGTH_LONG).show()
            return
        }
        val name = binding.inputName.text?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: if (jwt.isNotEmpty()) "JWT 账号" else "coding-plan 账号"

        val id = editingId ?: UUID.randomUUID().toString()
        val existing = if (editingId != null) {
            QuotaAccountStore.load(this).firstOrNull { it.id == id }
        } else null
        val account = existing ?: LlmAccount(id = id, name = name)
        account.name = name
        account.apiKey = key.ifEmpty { null }
        account.jwt = jwt.ifEmpty { null }
        account.teamOrg = binding.inputOrg.text?.toString()?.trim().orEmpty().ifEmpty { null }
        account.teamProj = binding.inputProj.text?.toString()?.trim().orEmpty().ifEmpty { null }
        QuotaAccountStore.upsert(this, account)
        finish()
    }

    companion object {
        private const val EXTRA_ID = "id"

        fun createIntent(context: Context, accountId: String?): Intent =
            Intent(context, AccountEditActivity::class.java).putExtra(EXTRA_ID, accountId)
    }
}
