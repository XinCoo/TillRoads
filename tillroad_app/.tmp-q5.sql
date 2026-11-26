SELECT local_id, q_type, error_layer, custom_reason, error_cause, status, sync_state FROM defect_tickets WHERE q_type='choice' OR custom_reason IS NOT NULL;
