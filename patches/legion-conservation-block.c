
/* ===== Battery conservation mode (cap charging ~60-80%) =====
 * SBMC 0x03 -> BTSM=1 (on), 0x05 -> BTSM=0 (off); status = GBMD & 0x20.
 * Verified against the 16IAX10H DSDT. Shares the SBMC/GBMD helpers with
 * rapidcharge (path now corrected to be relative to the bound VPC2004 device).
 */
#define FCT_CONSERVATION_ON 0x03
#define FCT_CONSERVATION_OFF 0x05

static int acpi_read_conservation(struct acpi_device *adev, bool *state)
{
	unsigned long result;
	int err;

	err = eval_gbmd(adev->handle, &result);
	if (err)
		return err;

	*state = result & 0x20;
	return 0;
}

static int acpi_write_conservation(struct acpi_device *adev, bool state)
{
	unsigned long fct_nr = state > 0 ? FCT_CONSERVATION_ON :
					   FCT_CONSERVATION_OFF;

	if (ec_readonly) {
		pr_info("Skip ACPI SBMC conservation write: ec_readonly=1\n");
		return 0;
	}

	return exec_sbmc(adev->handle, fct_nr);
}

static ssize_t conservation_mode_show(struct device *dev,
				      struct device_attribute *attr, char *buf)
{
	bool state = false;
	int err;
	struct legion_private *priv = dev_get_drvdata(dev);

	mutex_lock(&priv->fancurve_mutex);
	err = acpi_read_conservation(priv->adev, &state);
	mutex_unlock(&priv->fancurve_mutex);
	if (err)
		return -EINVAL;

	return sysfs_emit(buf, "%d\n", state);
}

static ssize_t conservation_mode_store(struct device *dev,
				       struct device_attribute *attr,
				       const char *buf, size_t count)
{
	struct legion_private *priv = dev_get_drvdata(dev);
	bool state;
	int err;

	err = kstrtobool(buf, &state);
	if (err)
		return err;

	mutex_lock(&priv->fancurve_mutex);
	err = acpi_write_conservation(priv->adev, state);
	mutex_unlock(&priv->fancurve_mutex);
	if (err)
		return -EINVAL;

	return count;
}

static DEVICE_ATTR_RW(conservation_mode);
