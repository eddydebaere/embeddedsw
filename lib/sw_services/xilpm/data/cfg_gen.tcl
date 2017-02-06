namespace eval ::pmufw {

proc get_template { file_name } {
	set fp [open $file_name r]
	set tmpl_data [read $fp]
	close $fp
	return $tmpl_data
}

#Lookout and load the template from this script's directory
set cfg_template [get_template [file join [file dirname [info script]] cfg_data.tpl]]

global master_list
set master_list {psu_cortexa53_0 psu_cortexr5_0 psu_cortexr5_1}
#=============================================================================#
# Get the IPI mask for a given master
#=============================================================================#
proc get_ipi_mask { master } {
	#Get the slave list for this master
	set slave_list [get_mem_ranges -of_objects [get_cells $master]];
	#Find the first IPI slave in the list
	set ipi [lsearch -inline $slave_list psu_ipi_* ];
	#Get the bit position property for the IPI instance
	set bit_pos [get_property CONFIG.C_BIT_POSITION -object [get_cells $ipi]];
	#Convert the bit position into MASK and return it
	return [format 0x%08X [expr 1<<$bit_pos]];
}

#=============================================================================#
# Get the Permission mask for a given slave node
#=============================================================================#
proc get_slave_perm_mask { slave } {
	 #List of Masters in the System
	 global master_list
	 set perm_mask 0x00000000
	 foreach master $pmufw::master_list {
		 #Get the slave list for this master
		 set slave_list [get_mem_ranges -of_objects [get_cells $master]];
		 #Search for the save in list
		 set slave_index [lsearch $slave_list $slave]
		 #if found, OR the master IPI mask to PERM mask
		 if { $slave_index >=0 } {
			set perm_mask [expr $perm_mask|[get_ipi_mask $master]]
		 }
	 }
	 #Return the mask in hex
	 return [format 0x%08X $perm_mask];
}

#=============================================================================#
# Get the Permission mask for a given OCM node
#=============================================================================#
proc get_tcm_perm_mask { tcm } {
	set perm_mask 0x00000000
	foreach master $pmufw::master_list {

		switch -glob $master {
		#For R5s, TCMs are always accessible
		"psu_cortexr5_*" {
			set perm_mask [expr $perm_mask|[get_ipi_mask $master]]
		}
		#for others it same as any other slave
		default {
			#Get the slave list for this master
			set slave_list [get_mem_ranges -of_objects [get_cells $master]];
			#Search for the slave in list
			set slave_index [lsearch $slave_list $tcm]
			#if found, OR the master IPI mask to PERM mask
			if { $slave_index >=0 } {
				set perm_mask [expr $perm_mask|[get_ipi_mask $master]]
			}
		}
		}
	 }
	#Return the mask in hex
	return [format 0x%08X $perm_mask];
}


set ocm_map [dict create]
dict set ocm_map psu_ocm_0 { label OCM_BANK_0 base 0xFFFC0000 high 0xFFFCFFFF }
dict set ocm_map psu_ocm_1 { label OCM_BANK_1 base 0xFFFD0000 high 0xFFFDFFFF }
dict set ocm_map psu_ocm_2 { label OCM_BANK_2 base 0xFFFE0000 high 0xFFFEFFFF }
dict set ocm_map psu_ocm_3 { label OCM_BANK_3 base 0xFFFF0000 high 0xFFFFFFFF }

#=============================================================================#
# Get the Permission mask for a given OCM node
#=============================================================================#
proc get_ocm_perm_mask { ocm } {
	set perm_mask 0x00000000
	#OCM island mem map
	#get the island_base and island_hi vals for ocm_label
	set island_base [dict get [dict get $pmufw::ocm_map $ocm] base]
	set island_high [dict get [dict get $pmufw::ocm_map $ocm] high]

	foreach master $pmufw::master_list {
		set plist [get_mem_ranges -of_objects [get_cells $master] psu_ocm_ram_0]
		if { [llength $plist] > 0} {
			foreach ocm_instance $plist {
				set base_val [get_property -object $ocm_instance -name BASE_VALUE]
				set high_val [get_property -object $ocm_instance -name HIGH_VALUE]
				# if island vals ffall in the instance range, then return the mask
				if { [expr ($island_base >= $base_val) && ($island_base <= $high_val)] || \
					[expr ($island_high >= $base_val) && ($island_high <= $high_val)]} {
					set perm_mask [expr $perm_mask|[get_ipi_mask $master]]
					break;
				}
			}
		}
	}
	#Return the mask in hex
	return [format 0x%08X $perm_mask];
}




#=============================================================================#
# Get the Permission mask for a given MEMORY node
#=============================================================================#
proc get_mem_perm_mask { mem } {
	set perm_mask 0x00000000

	switch -glob $mem {
		"psu_ddr" {
			set perm_mask [expr [get_slave_perm_mask psu_ddr_?]|[get_slave_perm_mask psu_r5_ddr_?]]
		}
		"psu_ocm_?" {
			set perm_mask [get_ocm_perm_mask $mem]
		}
		"psu_r5_*tcm_global" {
			set perm_mask [get_tcm_perm_mask $mem]
		}
		default {
			set perm_mask "0x00"
		}
	}
	#Return the mask in hex
	return [format 0x%08X $perm_mask];
}



proc convert_ipi_mask_to_txt { ipi_mask } {
	set macro_list {}
	foreach master $pmufw::master_list {
		if { [expr (($ipi_mask & [get_ipi_mask $master]) != 0)]  } {
			lappend macro_list [get_ipi_mask_txt $master]
		}
	}
	#Return the ORed macro list
	if { [llength $macro_list] >0 } {
		return [join $macro_list "| "];
	} else {
		return "0U";
	}
}


#=============================================================================#
# Return the Macro text for IPI mask of a Master
#=============================================================================#
proc get_ipi_mask_txt { master } {

	return "PM_CONFIG_IPI_[string toupper $master]_MASK"
}

#=============================================================================#
# Return the Macro text for IPI masks of a All Masters
#=============================================================================#
proc get_all_masters_mask_txt { } {
	set macro_list {}
	foreach master $pmufw::master_list {
		lappend macro_list [get_ipi_mask_txt $master]
	}
	return [join $macro_list "| "];
}


#=============================================================================#
# Get the ORed list of macros as Permission mask for a given slave node
#=============================================================================#
proc get_slave_perm_mask_txt { slave } {
	set macro_list {}
	foreach master $pmufw::master_list {
		#Get the slave list for this master
		set slave_list [get_mem_ranges -of_objects [get_cells $master]];
		#Search for the slave in list
		set slave_index [lsearch $slave_list $slave]
		#if found, add the macro to list
		if { $slave_index >=0 } {
			lappend macro_list [get_ipi_mask_txt $master]
		}
	}
	#Return the ORed macro list
	if { [llength $macro_list] >0 } {
		return [join $macro_list "| "];
	} else {
		return "0U";
	}
}





#puts "PMUFW Config Generator"
#puts [info script]

# Create a map of all the Nodes
#global node_map
set node_map [dict create]
dict set node_map NODE_APU { label NODE_APU periph psu_cortexa53_0 type processor }
dict set node_map NODE_APU_0 { label NODE_APU_0 periph psu_cortexa53_0 type processor }
dict set node_map NODE_APU_1 { label NODE_APU_1 periph psu_cortexa53_1 type processor }
dict set node_map NODE_APU_2 { label NODE_APU_2 periph psu_cortexa53_2 type processor }
dict set node_map NODE_APU_3 { label NODE_APU_3 periph psu_cortexa53_3 type processor }
dict set node_map NODE_RPU { label NODE_RPU periph psu_cortexr5_0 type processor }
dict set node_map NODE_RPU_0 { label NODE_RPU_0 periph psu_cortexr5_0 type processor }
dict set node_map NODE_RPU_1 { label NODE_RPU_1 periph psu_cortexr5_1 type processor }
dict set node_map NODE_PL { label NODE_PL periph NA type power }
dict set node_map NODE_FPD { label NODE_FPD periph NA type power }
dict set node_map NODE_OCM_BANK_0 { label NODE_OCM_BANK_0 periph psu_ocm_0 type memory }
dict set node_map NODE_OCM_BANK_1 { label NODE_OCM_BANK_1 periph psu_ocm_1 type memory }
dict set node_map NODE_OCM_BANK_2 { label NODE_OCM_BANK_2 periph psu_ocm_2 type memory }
dict set node_map NODE_OCM_BANK_3 { label NODE_OCM_BANK_3 periph psu_ocm_3 type memory }
dict set node_map NODE_TCM_0_A { label NODE_TCM_0_A periph psu_r5_0_atcm_global type memory }
dict set node_map NODE_TCM_0_B { label NODE_TCM_0_B periph psu_r5_0_btcm_global type memory }
dict set node_map NODE_TCM_1_A { label NODE_TCM_1_A periph psu_r5_1_atcm_global type memory }
dict set node_map NODE_TCM_1_B { label NODE_TCM_1_B periph psu_r5_1_btcm_global type memory }
dict set node_map NODE_L2 { label NODE_L2 periph NA type others }
dict set node_map NODE_GPU_PP_0 { label NODE_GPU_PP_0 periph psu_gpu type slave }
dict set node_map NODE_GPU_PP_1 { label NODE_GPU_PP_1 periph psu_gpu type slave }
dict set node_map NODE_USB_0 { label NODE_USB_0 periph psu_usb_0 type slave }
dict set node_map NODE_USB_1 { label NODE_USB_1 periph psu_usb_1 type slave }
dict set node_map NODE_TTC_0 { label NODE_TTC_0 periph psu_ttc_0 type slave }
dict set node_map NODE_TTC_1 { label NODE_TTC_1 periph psu_ttc_1 type slave }
dict set node_map NODE_TTC_2 { label NODE_TTC_2 periph psu_ttc_2 type slave }
dict set node_map NODE_TTC_3 { label NODE_TTC_3 periph psu_ttc_3 type slave }
dict set node_map NODE_SATA { label NODE_SATA periph psu_sata type slave }
dict set node_map NODE_ETH_0 { label NODE_ETH_0 periph psu_ethernet_0 type slave }
dict set node_map NODE_ETH_1 { label NODE_ETH_1 periph psu_ethernet_1 type slave }
dict set node_map NODE_ETH_2 { label NODE_ETH_2 periph psu_ethernet_2 type slave }
dict set node_map NODE_ETH_3 { label NODE_ETH_3 periph psu_ethernet_3 type slave }
dict set node_map NODE_UART_0 { label NODE_UART_0 periph psu_uart_0 type slave }
dict set node_map NODE_UART_1 { label NODE_UART_1 periph psu_uart_1 type slave }
dict set node_map NODE_SPI_0 { label NODE_SPI_0 periph psu_spi_0 type slave }
dict set node_map NODE_SPI_1 { label NODE_SPI_1 periph psu_spi_1 type slave }
dict set node_map NODE_I2C_0 { label NODE_I2C_0 periph psu_i2c_0 type slave }
dict set node_map NODE_I2C_1 { label NODE_I2C_1 periph psu_i2c_1 type slave }
dict set node_map NODE_SD_0 { label NODE_SD_0 periph psu_sd_0 type slave }
dict set node_map NODE_SD_1 { label NODE_SD_1 periph psu_sd_1 type slave }
dict set node_map NODE_DP { label NODE_DP periph psu_dp type slave }
dict set node_map NODE_GDMA { label NODE_GDMA periph psu_gdma_0 type slave }
dict set node_map NODE_ADMA { label NODE_ADMA periph psu_adma_0 type slave }
dict set node_map NODE_NAND { label NODE_NAND periph psu_nand_0 type slave }
dict set node_map NODE_QSPI { label NODE_QSPI periph psu_qspi_0 type slave }
dict set node_map NODE_GPIO { label NODE_GPIO periph psu_gpio_0 type slave }
dict set node_map NODE_CAN_0 { label NODE_CAN_0 periph psu_can_0 type slave }
dict set node_map NODE_CAN_1 { label NODE_CAN_1 periph psu_can_1 type slave }
dict set node_map NODE_EXTERN { label NODE_EXTERN periph NA type others }
dict set node_map NODE_DDR { label NODE_DDR periph psu_ddr type memory }
dict set node_map NODE_IPI_APU { label NODE_IPI_APU periph NA type ipi }
dict set node_map NODE_IPI_RPU_0 { label NODE_IPI_RPU_0 periph NA type ipi }
dict set node_map NODE_GPU { label NODE_GPU periph psu_gpu type slave }
dict set node_map NODE_PCIE { label NODE_PCIE periph psu_pcie type slave }
dict set node_map NODE_PCAP { label NODE_PCAP periph NA type slave }
dict set node_map NODE_RTC { label NODE_RTC periph psu_rtc type slave }



proc get_slave_section { } {
	#global node_map
	set slave_count 0
	set slave_text ""

	# Loop through each node
	foreach node [dict keys $pmufw::node_map] {
		set periph_name [dict get [dict get $pmufw::node_map $node] periph]
		set periph_type [dict get [dict get $pmufw::node_map $node] type]
		set periph_label [dict get [dict get $pmufw::node_map $node] label]

		# Process nodes of type "SLAVE". if periph_type is NA, sets perm to 0U
		if { ($periph_type == "slave")} {

			#Increment the slave count
			incr slave_count

			#set the perms(ipi mask) value for this node
			dict set pmufw::node_map $node perms [get_slave_perm_mask_txt $periph_name]
			#print out for debug purpose
			#puts "$periph_name \t: [dict get [dict get $pmufw::node_map $node] perms] "

			#concat to the slave data text
			#append  slave_text "\t/**********************************************************************/\n"
			append  slave_text "\t[dict get [dict get $pmufw::node_map $node] label],\n"
			append  slave_text "\tPM_SLAVE_FLAG_IS_SHAREABLE,\n"
			append  slave_text "\t[dict get [dict get $pmufw::node_map $node] perms], /* IPI Mask */\n\n"
		}
		# Process nodes of type "MEMORY"
		if { ($periph_type == "memory") && ($periph_name != "NA") } {

			#Increment the slave count
			incr slave_count

			#set the perms(ipi mask) value for this node
			dict set pmufw::node_map $node perms [convert_ipi_mask_to_txt [get_mem_perm_mask $periph_name]]
			#print out for debug purpose
			#puts "$periph_name \t: [dict get [dict get $pmufw::node_map $node] perms] "

			#concat to the slave data text
			#append  slave_text "\t/**********************************************************************/\n"
			append  slave_text "\t[dict get [dict get $pmufw::node_map $node] label],\n"
			append  slave_text "\tPM_SLAVE_FLAG_IS_SHAREABLE,\n"
			append  slave_text "\t[dict get [dict get $pmufw::node_map $node] perms], /* IPI Mask */\n\n"
		}

		# Process nodes of type "others"
		if { ($periph_type == "others") } {

			#Increment the slave count
			incr slave_count

			#set the perms(ipi mask) value for this node
			dict set pmufw::node_map $node perms [get_all_masters_mask_txt]
			#print out for debug purpose
			#puts "$periph_name \t: [dict get [dict get $pmufw::node_map $node] perms] "

			#concat to the slave data text
			#append  slave_text "\t/**********************************************************************/\n"
			append  slave_text "\t[dict get [dict get $pmufw::node_map $node] label],\n"
			append  slave_text "\tPM_SLAVE_FLAG_IS_SHAREABLE,\n"
			append  slave_text "\t[dict get [dict get $pmufw::node_map $node] perms], /* IPI Mask */\n\n"
		}

		#Process nodes of type IPI
		set ipi_perm ""
		if { ($periph_type == "ipi")} {

			#puts $periph_label
			switch $periph_label {
				"NODE_IPI_APU" {
					set ipi_perm [get_ipi_mask_txt psu_cortexa53_0]
				}
				"NODE_IPI_RPU_0" {
					set ipi_perm [get_ipi_mask_txt psu_cortexr5_0]
				}
				default {
					set ipi_perm ""
				}
			}
			if { $ipi_perm != "" } {
				#Increment the slave count
				incr slave_count

				#set the perms(ipi mask) value for this node
				dict set pmufw::node_map $node perms $ipi_perm
				#concat to the slave data text
				#append  slave_text "\t/**********************************************************************/\n"
				append  slave_text "\t[dict get [dict get $pmufw::node_map $node] label],\n"
				append  slave_text "\t0U,\n"
				append  slave_text "\t[dict get [dict get $pmufw::node_map $node] perms], /* IPI Mask */\n\n"
			}
		}

	}

	set slave_text "

\tPM_CONFIG_SLAVE_SECTION_ID,	/* Section ID */
\t$slave_count,				/* Number of slaves */

$slave_text"

	return $slave_text
}

proc get_master_ipidef { } {
	set master_ipidef "\n"
	foreach master $pmufw::master_list {
		append master_ipidef "#define "  [get_ipi_mask_txt $master] "    " [get_ipi_mask $master] "\n"
	}
	append master_ipidef "\n"

	return $master_ipidef
}


proc get_master_section { } {
	# Placeholder for the code
	set master_text ""

	#We cover only APU and RPU masters
	#Currently PCW doesnt provide a choice for LS/SPlit for RPUs
	#So dump the data for all valid masters (APU, R5_), R5_1

	append master_text "\tPM_CONFIG_MASTER_SECTION_ID, /* Master SectionID */" "\n"
	append master_text "\t3U, /* No. of Masters*/" "\n"
	append master_text "\n"

	# Define APU
	append master_text "\tNODE_APU, /* Master Node ID */" "\n"
	append master_text "\t[get_ipi_mask_txt psu_cortexa53_0], /* IPI Mask of this master */" "\n"
	append master_text "\tSUSPEND_TIMEOUT, /* Suspend timeout */" "\n"
	append master_text "\t[get_ipi_mask_txt psu_cortexr5_0], /* Suspend permissions */" "\n"
	append master_text "\t[get_ipi_mask_txt psu_cortexr5_0], /* Wake permissions */" "\n"
	append master_text "\n"

	# Define R5_0
	append master_text "\tNODE_RPU_0, /* Master Node ID */" "\n"
	append master_text "\t[get_ipi_mask_txt psu_cortexr5_0], /* IPI Mask of this master */" "\n"
	append master_text "\tSUSPEND_TIMEOUT, /* Suspend timeout */" "\n"
	append master_text "\t[get_ipi_mask_txt psu_cortexa53_0], /* Suspend permissions */" "\n"
	append master_text "\t[get_ipi_mask_txt psu_cortexa53_0], /* Wake permissions */" "\n"
	append master_text "\n"

	# Define R5_1
	append master_text "\tNODE_RPU_1, /* Master Node ID */" "\n"
	append master_text "\t[get_ipi_mask_txt psu_cortexr5_1], /* IPI Mask of this master */" "\n"
	append master_text "\tSUSPEND_TIMEOUT, /* Suspend timeout */" "\n"
	append master_text "\t[get_ipi_mask_txt psu_cortexa53_0], /* Suspend permissions */" "\n"
	append master_text "\t[get_ipi_mask_txt psu_cortexa53_0], /* Wake permissions */"	 "\n"
	append master_text "\n"


	return $master_text
}

proc get_prealloc_for_master_txt { master_name prealloc_list } {
	set node_count 0
	set master_prealloc_txt ""

	set master_mask [get_ipi_mask_txt $master_name]
	foreach node $prealloc_list {
		set periph_perms [dict get [dict get $pmufw::node_map $node] perms]
		set periph_name [dict get [dict get $pmufw::node_map $node] periph]
		set periph_type [dict get [dict get $pmufw::node_map $node] type]
		set periph_label [dict get [dict get $pmufw::node_map $node] label]

		if { [string first $master_mask $periph_perms ] >= 0 } {
			append master_prealloc_txt "\t$periph_label," "\n"
			append master_prealloc_txt "\tPM_MASTER_USING_SLAVE_MASK, /* Master is using Slave */" "\n"
			append master_prealloc_txt "\tPM_CAP_ACCESS | PM_CAP_CONTEXT, /* Current Requirements */" "\n"
			append master_prealloc_txt "\tPM_CAP_ACCESS | PM_CAP_CONTEXT, /* Default Requirements */" "\n"
			append master_prealloc_txt "\n"
			incr node_count
		}
	}

	set master_prealloc_txt "/* Prealloc for $master_name */
	$master_mask,
	$node_count,
$master_prealloc_txt
	"
	return $master_prealloc_txt
}

proc get_prealloc_section { } {
	set prealloc_text "\n"
	set apu_prealloc_list {NODE_IPI_APU NODE_DDR NODE_L2 NODE_OCM_BANK_0 NODE_OCM_BANK_1 NODE_OCM_BANK_2 NODE_OCM_BANK_3}
	set rpu_prealloc_list {NODE_IPI_RPU_0 NODE_TCM_0_A NODE_TCM_0_B NODE_TCM_1_A NODE_TCM_1_B}

	append prealloc_text "\tPM_CONFIG_PREALLOC_SECTION_ID, /* Preallaoc SectionID */" "\n"
	append prealloc_text "\t2U, /* No. of Masters*/" "\n"
	append prealloc_text "\n"

	append prealloc_text [get_prealloc_for_master_txt psu_cortexa53_0 $apu_prealloc_list]
	append prealloc_text [get_prealloc_for_master_txt psu_cortexr5_0 $rpu_prealloc_list]

	return $prealloc_text
}

proc gen_cfg_data { cfg_fname } {
# Open file and dump the data
set cfg_fid [open $cfg_fname w]

set pmufw::cfg_template [string map [list "<<MASTER_IPI_MASK_DEF>>" "[get_master_ipidef]"] $pmufw::cfg_template]
set pmufw::cfg_template [string map [list "<<MASTER_SECTION_DATA>>" "[get_master_section]"] $pmufw::cfg_template]
set pmufw::cfg_template [string map [list "<<SLAVE_SECTION_DATA>>" "[get_slave_section]"] $pmufw::cfg_template]
set pmufw::cfg_template [string map [list "<<PREALLOC_SECTION_DATA>>" "[get_prealloc_section]"] $pmufw::cfg_template]

puts $cfg_fid "$pmufw::cfg_template"
close $cfg_fid
#puts $node_map

}

}
